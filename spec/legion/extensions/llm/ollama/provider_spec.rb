# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/ollama/provider'

RSpec.describe Legion::Extensions::Llm::Ollama::Provider do
  subject(:provider) { described_class.new(config) }

  let(:config) do
    { base_url: 'http://127.0.0.1:11434', request_timeout: 60, stream_timeout: 300,
      instance_id: :default, tier: :local, transport: :http }
  end

  # -----------------------------------------------------------------------
  # Helpers shared across streaming examples
  # -----------------------------------------------------------------------
  def ndjson(obj)
    "#{Legion::JSON.dump(obj)}\n"
  end

  def drain(buffer, chunks, block = nil)
    provider.send(:drain_ndjson_buffer, buffer, chunks, block)
  end

  def finalize(chunks)
    provider.send(:finalize_stream, chunks)
  end

  def build_chunks(*lines)
    chunks = []
    lines.each { |line| drain(line, chunks) }
    chunks
  end

  def build_chunk(data)
    provider.send(:build_chunk, data)
  end

  def stub_response(body)
    instance_double(Faraday::Response, body: body)
  end

  def completion_response(content:, model: 'qwen3:latest', thinking: nil, tokens: [10, 5])
    body = {
      'model' => model,
      'message' => { 'role' => 'assistant', 'content' => content }.tap { |m| m['thinking'] = thinking if thinking },
      'prompt_eval_count' => tokens[0],
      'eval_count' => tokens[1]
    }
    provider.send(:parse_completion_response, stub_response(body))
  end

  # -----------------------------------------------------------------------
  # NDJSON streaming parser — drain_ndjson_buffer
  # -----------------------------------------------------------------------
  describe '#drain_ndjson_buffer' do
    let(:chunks) { [] }

    it 'parses a single complete NDJSON line and empties the buffer' do
      buf = ndjson('message' => { 'content' => 'hello' })
      drain(buf, chunks)
      expect(chunks.first.content).to eq('hello')
      expect(buf).to be_empty
    end

    it 'parses multiple lines in one call' do
      buf = ndjson('message' => { 'content' => 'a' }) +
            ndjson('message' => { 'content' => 'b' })
      drain(buf, chunks)
      expect(chunks.map(&:content)).to eq(%w[a b])
    end

    it 'yields each chunk to the block' do
      buf = ndjson('message' => { 'content' => 'x' }) +
            ndjson('message' => { 'content' => 'y' })
      yielded = []
      drain(buf, chunks, proc { |c| yielded << c })
      expect(yielded.map(&:content)).to eq(%w[x y])
    end

    context 'with a split input buffer' do
      let(:buf) { +'{"message":{"con' }

      it 'holds the partial line and yields nothing' do
        drain(buf, chunks)
        expect(chunks).to be_empty
      end

      it 'parses the line once the rest arrives' do
        drain(buf, chunks)
        buf << %(tent":"world"}}\n)
        drain(buf, chunks)
        expect(chunks.first.content).to eq('world')
      end
    end

    it 'skips blank lines silently' do
      buf = "\n\n#{ndjson('message' => { 'content' => 'ok' })}"
      drain(buf, chunks)
      expect(chunks.size).to eq(1)
    end

    it 'skips malformed JSON lines without raising and parses the valid line' do
      buf = %(not json\n#{ndjson('message' => { 'content' => 'valid' })})
      expect { drain(buf, chunks) }.not_to raise_error
      expect(chunks.first.content).to eq('valid')
    end
  end

  # -----------------------------------------------------------------------
  # NDJSON streaming parser — finalize_stream
  # -----------------------------------------------------------------------
  describe '#finalize_stream' do
    it 'returns a nil-content assistant Message when chunks is empty' do
      result = finalize([])
      expect(result).to be_a(Legion::Extensions::Llm::Message)
      expect(result.content).to be_nil
    end

    context 'with two content chunks' do
      let(:chunks) do
        build_chunks(ndjson('message' => { 'content' => 'hel' }), ndjson('message' => { 'content' => 'lo' }))
      end

      it 'joins content from all chunks' do
        expect(finalize(chunks).content).to eq('hello')
      end
    end

    context 'with a done chunk carrying token counts' do
      let(:chunks) do
        build_chunks(
          ndjson('message' => { 'content' => 'a' }),
          ndjson('message' => { 'content' => 'b' }, 'done' => true, 'prompt_eval_count' => 7, 'eval_count' => 4)
        )
      end

      it 'picks input tokens from the final done chunk' do
        expect(finalize(chunks).input_tokens).to eq(7)
      end

      it 'picks output tokens from the final done chunk' do
        expect(finalize(chunks).output_tokens).to eq(4)
      end
    end

    context 'with thinking chunks followed by a content chunk' do
      let(:chunks) do
        build_chunks(
          ndjson('message' => { 'content' => '', 'thinking' => 'step 1' }),
          ndjson('message' => { 'content' => '', 'thinking' => ' step 2' }),
          ndjson('message' => { 'content' => 'answer' }, 'done' => true)
        )
      end

      it 'concatenates thinking text from all chunks' do
        expect(finalize(chunks).thinking.text).to eq('step 1 step 2')
      end

      it 'preserves the final content' do
        expect(finalize(chunks).content).to eq('answer')
      end
    end

    context 'with a tool_calls chunk' do
      let(:tc) { [{ 'function' => { 'name' => 'lookup', 'arguments' => { 'q' => 'foo' } } }] }
      let(:chunks) { build_chunks(ndjson('message' => { 'content' => '', 'tool_calls' => tc }, 'done' => true)) }

      it 'includes the tool call key in the finalized message' do
        expect(finalize(chunks).tool_calls.keys).to contain_exactly(:lookup)
      end

      it 'preserves tool call arguments' do
        expect(finalize(chunks).tool_calls[:lookup].arguments).to eq({ 'q' => 'foo' })
      end
    end
  end

  # -----------------------------------------------------------------------
  # NDJSON streaming parser — build_chunk
  # -----------------------------------------------------------------------
  describe '#build_chunk' do
    it 'returns a Chunk with the correct content' do
      chunk = build_chunk('message' => { 'content' => 'word' })
      expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
      expect(chunk.content).to eq('word')
    end

    it 'attaches a Thinking object when the message thinking field is present' do
      chunk = build_chunk('message' => { 'content' => '', 'thinking' => 'reasoning' })
      expect(chunk.thinking).to be_a(Legion::Extensions::Llm::Thinking)
      expect(chunk.thinking.text).to eq('reasoning')
    end

    it 'leaves thinking nil when the message has no thinking field' do
      chunk = build_chunk('message' => { 'content' => 'text' })
      expect(chunk.thinking).to be_nil
    end

    it 'parses tool_calls into a hash of ToolCall objects' do
      tc = [{ 'function' => { 'name' => 'greet', 'arguments' => { 'name' => 'world' } } }]
      chunk = build_chunk('message' => { 'content' => '', 'tool_calls' => tc })
      expect(chunk.tool_calls[:greet]).to be_a(Legion::Extensions::Llm::ToolCall)
      expect(chunk.tool_calls[:greet].arguments).to eq({ 'name' => 'world' })
    end
  end

  # -----------------------------------------------------------------------
  # Non-streaming thinking extraction — parse_completion_response
  # -----------------------------------------------------------------------
  describe '#parse_completion_response' do
    it 'strips <think> tags from visible content and populates thinking' do
      msg = completion_response(content: '<think>step by step</think>final answer')
      expect(msg.content).to eq('final answer')
      expect(msg.thinking.text).to eq('step by step')
    end

    it 'populates thinking from message-level thinking metadata' do
      msg = completion_response(content: 'answer', thinking: 'metadata reasoning')
      expect(msg.content).to eq('answer')
      expect(msg.thinking.text).to eq('metadata reasoning')
    end

    it 'returns nil thinking when content has no <think> tags and no metadata' do
      msg = completion_response(content: 'plain response')
      expect(msg.thinking&.text).to be_nil
      expect(msg.content).to eq('plain response')
    end

    it 'records token counts from prompt_eval_count and eval_count' do
      msg = completion_response(content: 'ok', tokens: [12, 6])
      expect(msg.input_tokens).to eq(12)
      expect(msg.output_tokens).to eq(6)
    end
  end
end
