# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ollama do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:qwen_model) { Legion::Extensions::Llm::Model::Info.new(id: 'qwen3.6:27b', provider: :ollama) }

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:ollama)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('http://localhost:11434')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:ollama)).to eq(described_class::Provider)
  end

  it 'exposes provider base endpoint helpers' do
    expect([provider.api_base, provider.completion_url, provider.models_url])
      .to eq(['http://localhost:11434', '/api/chat', '/api/tags'])
  end

  it 'exposes Ollama management endpoint helpers' do
    expect(provider.running_models_url).to eq('/api/ps')
    expect(provider.show_model_url).to eq('/api/show')
    expect(provider.pull_url).to eq('/api/pull')
    expect(provider.embedding_url(model: 'nomic-embed-text')).to eq('/api/embed')
  end

  it 'renders chat payloads in the Ollama message format' do
    payload = chat_payload

    expect(payload.values_at(:model, :stream, :think)).to eq(['qwen3.6:27b', false, true])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
    expect(payload[:options]).to eq({ temperature: 0.2 })
  end

  it 'parses current and legacy Ollama embedding responses' do
    current = embedding_for('embeddings' => [[0.1, 0.2]], 'prompt_eval_count' => 3)
    legacy = embedding_for('embedding' => [0.3, 0.4])

    expect([current.vectors, current.input_tokens, legacy.vectors]).to eq([[0.1, 0.2], 3, [0.3, 0.4]])
  end

  def chat_payload
    message = Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')
    provider.send(:render_payload, [message], tools: {}, temperature: 0.2, model: qwen_model, stream: false,
                                              schema: nil, thinking: true, tool_prefs: nil)
  end

  def embedding_for(body)
    provider.send(:parse_embedding_response, fake_response(body), model: 'nomic-embed-text', text: 'hello')
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end
end
