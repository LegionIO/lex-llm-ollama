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

  def drain(buffer, accumulator, block = nil)
    provider.send(:drain_ndjson_buffer, buffer, accumulator, block)
  end

  def build_chunk(data)
    provider.send(:build_chunk, data)
  end

  def stub_response(body)
    instance_double(Faraday::Response, body: body)
  end

  def completion_response(content:, model: 'qwen3:latest', thinking: nil, tokens: [10, 5],
                          done: nil, tool_calls: nil)
    message = { 'role' => 'assistant', 'content' => content }
    message['thinking'] = thinking if thinking
    message['tool_calls'] = tool_calls if tool_calls
    body = {
      'model' => model,
      'message' => message,
      'prompt_eval_count' => tokens[0],
      'eval_count' => tokens[1]
    }
    body['done'] = done if done
    body['done_reason'] = 'stop' if done
    provider.send(:parse_completion_response, stub_response(body))
  end

  # -----------------------------------------------------------------------
  # One chunk-parse boundary — build_chunk (08 R2, asserted by type)
  # -----------------------------------------------------------------------
  describe '#build_chunk' do
    it 'returns a Canonical::Chunk text delta with the wire content' do
      chunk = build_chunk('message' => { 'content' => 'word' })
      expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunk).to be_text_delta
      expect(chunk.delta).to eq('word')
    end

    it 'returns a Canonical::Chunk thinking delta when the thinking field is present' do
      chunk = build_chunk('message' => { 'content' => '', 'thinking' => 'reasoning' })
      expect(chunk).to be_thinking_delta
      expect(chunk.delta).to eq('reasoning')
    end

    it 'returns a Canonical::Chunk tool-call delta carrying the accumulator fragment' do
      tc = [{ 'function' => { 'name' => 'greet', 'arguments' => { 'name' => 'world' } } }]
      chunk = build_chunk('message' => { 'content' => '', 'tool_calls' => tc })
      expect(chunk).to be_tool_call_delta
      expect(chunk.tool_call).to be_a(Hash)
      expect(chunk.tool_call[:name]).to eq('greet')
      expect(chunk.tool_call[:arguments]).to be_a(String)
      expect(Legion::JSON.load(chunk.tool_call[:arguments])).to eq(name: 'world')
    end

    it 'returns a done chunk with usage and stop reason on the final wire line' do
      chunk = build_chunk('message' => { 'content' => '' }, 'done' => true, 'done_reason' => 'stop',
                          'prompt_eval_count' => 7, 'eval_count' => 4)
      expect(chunk).to be_done
      expect(chunk.stop_reason).to eq(:end_turn)
      expect(chunk.usage.input_tokens).to eq(7)
      expect(chunk.usage.output_tokens).to eq(4)
    end
  end

  # -----------------------------------------------------------------------
  # NDJSON streaming parser — drain_ndjson_buffer (feeds the shared accumulator)
  # -----------------------------------------------------------------------
  describe '#drain_ndjson_buffer' do
    let(:accumulator) { Legion::Extensions::Llm::StreamAccumulator.new }
    let(:emitted) { [] }
    let(:block) { proc { |chunk| emitted << chunk } }

    it 'emits a Canonical::Chunk per complete NDJSON line and empties the buffer' do
      buf = ndjson('message' => { 'content' => 'hello' })
      drain(buf, accumulator, block)
      expect(emitted).to all(be_a(Legion::Extensions::Llm::Canonical::Chunk))
      expect(emitted.map(&:delta)).to eq(['hello'])
      expect(buf).to be_empty
    end

    it 'emits each chunk to the block in order' do
      buf = ndjson('message' => { 'content' => 'a' }) + ndjson('message' => { 'content' => 'b' })
      drain(buf, accumulator, block)
      expect(emitted.map(&:delta)).to eq(%w[a b])
    end

    context 'with a split input buffer' do
      let(:buf) { +'{"message":{"con' }

      it 'holds the partial line and yields nothing' do
        drain(buf, accumulator, block)
        expect(emitted).to be_empty
      end

      it 'emits the line once the rest arrives' do
        drain(buf, accumulator, block)
        buf << %(tent":"world"}}\n)
        drain(buf, accumulator, block)
        expect(emitted.map(&:delta)).to eq(['world'])
      end
    end

    it 'skips blank lines and malformed JSON lines without raising' do
      buf = "\n\nnot json\n#{ndjson('message' => { 'content' => 'valid' })}"
      expect { drain(buf, accumulator, block) }.not_to raise_error
      expect(emitted.map(&:delta)).to eq(['valid'])
    end
  end

  # -----------------------------------------------------------------------
  # Streaming contract — stream_response (05 O5, 08 R2)
  # -----------------------------------------------------------------------
  describe '#stream_response' do
    def fake_streaming_connection(lines, status: 200)
      connection = Object.new
      connection.define_singleton_method(:post) do |_path, _payload, &request_block|
        req = Struct.new(:headers, :options).new({}, Struct.new(:on_data).new(nil))
        request_block&.call(req)
        env = Faraday::Env.new
        env.status = status
        lines.each { |line| req.options.on_data.call(line, line.bytesize, env) }
        Struct.new(:body).new('')
      end
      connection
    end

    # Drives the PUBLIC funnel (stream_chat -> complete -> render_payload ->
    # stream_response) so the whole production path executes; the fake
    # connection replaces only the HTTP boundary.
    def run_stream(lines, status: 200)
      provider.instance_variable_set(:@connection, fake_streaming_connection(lines, status: status))
      chunks = []
      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]
      response = provider.stream_chat(messages, model: 'qwen3:8b') { |chunk| chunks << chunk }
      [response, chunks]
    end

    it 'yields Canonical::Chunk and ends in exactly one done chunk' do
      _response, chunks = run_stream(
        [
          ndjson('message' => { 'content' => 'hel' }),
          ndjson('message' => { 'content' => 'lo' }),
          ndjson('message' => { 'content' => '' }, 'done' => true, 'done_reason' => 'stop',
                 'prompt_eval_count' => 7, 'eval_count' => 4)
        ]
      )

      expect(chunks).to all(be_a(Legion::Extensions::Llm::Canonical::Chunk))
      expect(chunks.count(&:done?)).to eq(1)
      expect(chunks.last).to be_done
    end

    it 'returns the accumulated Canonical::Response (assembled by the shared accumulator)' do
      response, = run_stream(
        [
          ndjson('message' => { 'content' => 'hel' }),
          ndjson('message' => { 'content' => 'lo' }),
          ndjson('message' => { 'content' => '' }, 'done' => true, 'done_reason' => 'stop',
                 'prompt_eval_count' => 7, 'eval_count' => 4)
        ]
      )

      expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(response.text).to eq('hello')
      expect(response.model).to eq('qwen3:8b')
      expect(response.stop_reason).to eq(:end_turn)
      expect(response.usage.input_tokens).to eq(7)
      expect(response.usage.output_tokens).to eq(4)
    end

    it 'assembles thinking deltas from the wire thinking field' do
      response, = run_stream(
        [
          ndjson('message' => { 'content' => '', 'thinking' => 'step 1' }),
          ndjson('message' => { 'content' => '', 'thinking' => ' step 2' }),
          ndjson('message' => { 'content' => 'answer' }, 'done' => true, 'done_reason' => 'stop')
        ]
      )

      expect(response.text).to eq('answer')
      expect(response.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking)
      expect(response.thinking.content).to eq('step 1 step 2')
    end

    it 'raises the typed error and emits an error chunk on a non-200 stream' do
      chunks = []
      error_lines = [ndjson('error' => 'Server busy')]
      provider.instance_variable_set(:@connection, fake_streaming_connection(error_lines, status: 503))
      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]
      expect do
        provider.stream_chat(messages, model: 'qwen3:8b') { |chunk| chunks << chunk }
      end.to raise_error(Legion::Extensions::Llm::ServerError)

      expect(chunks.last).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunks.last).to be_error
    end
  end

  # -----------------------------------------------------------------------
  # One response-parse boundary — parse_completion_response (08 R2, by type)
  # -----------------------------------------------------------------------
  describe '#parse_completion_response' do
    it 'returns a Canonical::Response with think tags stripped into thinking' do
      msg = completion_response(content: 'step by step
</think>
final answer')
      expect(msg).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(msg.text).to eq('final answer')
      expect(msg.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking)
      expect(msg.thinking.content).to eq('step by step')
    end

    it 'populates thinking from message-level thinking metadata' do
      msg = completion_response(content: 'answer', thinking: 'metadata reasoning')
      expect(msg.text).to eq('answer')
      expect(msg.thinking.content).to eq('metadata reasoning')
    end

    it 'returns nil thinking when content has no think tags and no metadata' do
      msg = completion_response(content: 'plain response')
      expect(msg.thinking).to be_nil
      expect(msg.text).to eq('plain response')
    end

    it 'records usage from prompt_eval_count and eval_count' do
      msg = completion_response(content: 'ok', tokens: [12, 6])
      expect(msg.usage).to be_a(Legion::Extensions::Llm::Canonical::Usage)
      expect(msg.usage.input_tokens).to eq(12)
      expect(msg.usage.output_tokens).to eq(6)
    end

    it 'maps the done_reason wire spelling to the canonical stop reason' do
      msg = completion_response(content: 'ok', done: true)
      expect(msg.stop_reason).to eq(:end_turn)
    end

    it 'parses structured tool calls into Array<Canonical::ToolCall>' do
      tc = [{ 'function' => { 'name' => 'lookup', 'arguments' => { 'q' => 'foo' } } }]
      msg = completion_response(content: '', tool_calls: tc)
      expect(msg.tool_call?).to be(true)
      expect(msg.tool_calls).to all(be_a(Legion::Extensions::Llm::Canonical::ToolCall))
      expect(msg.tool_calls.first.name).to eq('lookup')
      expect(msg.tool_calls.first.arguments).to eq('q' => 'foo')
    end
  end

  # -----------------------------------------------------------------------
  # Render boundary — render_payload (08 R1: renders FROM canonical values)
  # -----------------------------------------------------------------------
  describe '#render_payload' do
    def render(messages, **overrides)
      kwargs = {
        tools: {}, params: nil, model: 'qwen3:8b', stream: false, schema: nil,
        thinking: nil, tool_prefs: nil
      }.merge(overrides)
      provider.send(:render_payload, messages, **kwargs)
    end

    let(:user_message) { Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello') }

    it 'renders canonical params into the Ollama options wire keys' do
      params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2, max_tokens: 1024)
      payload = render([user_message], params: params)
      expect(payload[:options]).to eq(temperature: 0.2, num_predict: 1024)
    end

    it 'renders an empty options hash and think: false when no params or thinking are set' do
      payload = render([user_message])
      expect(payload[:options]).to eq({})
      expect(payload[:think]).to be(false)
    end

    it 'renders think: true for an enabled Thinking::Config' do
      thinking = Legion::Extensions::Llm::Canonical::Thinking::Config.build(effort: 'medium')
      payload = render([user_message], thinking: thinking)
      expect(payload[:think]).to be(true)
    end

    it 'renders canonical messages in the Ollama message format' do
      payload = render([user_message])
      expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
      expect(payload[:model]).to eq('qwen3:8b')
      expect(payload[:stream]).to be(false)
    end

    it 'renders image content blocks as the Ollama images array, not the content string' do
      image = Legion::Extensions::Llm::Canonical::ContentBlock.image(data: 'aGk=', media_type: 'image/png')
      message = Legion::Extensions::Llm::Canonical::Message.build(
        role: :user, content: [Legion::Extensions::Llm::Canonical::ContentBlock.text('hi'), image]
      )
      payload = render([message])
      expect(payload[:messages].first[:content]).to eq('hi')
      expect(payload[:messages].first[:images]).to eq(['aGk='])
    end

    it 'renders tool-role messages with their tool_call_id' do
      message = Legion::Extensions::Llm::Canonical::Message.build(
        role: :tool, content: 'result', tool_call_id: 'call_1'
      )
      payload = render([message])
      expect(payload[:messages].first).to eq(role: 'tool', content: 'result', tool_call_id: 'call_1')
    end
  end
end
