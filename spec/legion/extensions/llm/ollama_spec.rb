# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ollama do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:qwen_model) { Legion::Extensions::Llm::Model::Info.new(id: 'qwen3.6:27b', provider: :ollama) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

  it 'exposes provider defaults with the full settings schema' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings).to include(enabled: true, provider_family: :ollama)
    expect(instance).to include(endpoint: 'http://127.0.0.1:11434', default_model: 'qwen3.5:latest',
                                tier: :local, transport: :http)
    expect(instance).to include(fleet: hash_including(respond_to_requests: false),
                                usage: hash_including(embedding: true))
  end

  it 'provides a registry_publisher backed by the shared base class' do
    publisher = described_class.registry_publisher

    expect(publisher).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(publisher.provider_family).to eq(:ollama)
  end

  it 'uses the Legion logging helper on extension and provider surfaces' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
    expect(described_class::Provider.ancestors).to include(Legion::Logging::Helper)
  end

  it 'exposes provider base endpoint helpers' do
    expect([provider.api_base, provider.completion_url, provider.models_url])
      .to eq(['http://127.0.0.1:11434', '/api/chat', '/api/tags'])
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

  it 'renders embedding payloads with model ids' do
    embed_model = Legion::Extensions::Llm::Model::Info.new(id: 'nomic-embed-text:latest', provider: :ollama)
    payload = provider.send(:render_embedding_payload, 'hello', model: embed_model, dimensions: nil)

    expect(payload).to eq(model: 'nomic-embed-text:latest', input: 'hello')
  end

  it 'does not assume GGUF chat models support tools without Ollama capability metadata' do
    models = parse_models('models' => [{ 'name' => 'hf.co/unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL' }])

    expect(models.first.capabilities).to include(:completion, :streaming)
    expect(models.first.capabilities).not_to include(:tools)
  end

  it 'advertises tools only when Ollama reports tools capability metadata' do
    models = parse_models('models' => [{ 'name' => 'qwen-tools', 'capabilities' => %w[completion tools] }])

    expect(models.first.capabilities).to include(:completion, :streaming, :tools)
  end

  it 'publishes live readiness asynchronously through the registry publisher' do
    stub_registry_publisher

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'publishes discovered models asynchronously through the registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :ollama, live: false))
  end

  it 'does not probe Ollama for uncached non-live offerings reads' do
    allow(provider).to receive(:list_models).and_raise('unexpected live discovery')

    expect(provider.discover_offerings).to eq([])
    expect(provider).not_to have_received(:list_models)
  end

  it 'serves non-live offerings reads from the live discovery cache' do
    stub_model_discovery
    live_offerings = provider.discover_offerings(live: true)
    allow(provider).to receive(:list_models).and_raise('unexpected live discovery')

    expect(provider.discover_offerings.map(&:model)).to eq(live_offerings.map(&:model))
  end

  it 'uses provider instance transport and tier in discovered offerings' do
    configured = described_class::Provider.new(instance_id: :fleet_node, transport: :rabbitmq, tier: :fleet)
    offering = configured.send(:offering_from_model, qwen_model)

    expect(offering.to_h).to include(instance_id: :fleet_node, transport: :rabbitmq, tier: :fleet)
  end

  it 'marks offerings discovery fallback exceptions as handled' do
    stub_cached_offering_failure

    expect(provider.discover_offerings).to eq([])
  end

  it 'annotates offerings with loaded: true for running models' do
    stub_model_discovery
    offerings = provider.discover_offerings(live: true)

    expect(offerings.first.metadata[:loaded]).to be(true)
  end

  it 'annotates offerings with loaded: false for registered but not running models' do
    allow(provider.connection).to receive(:get).with('/api/tags').and_return(
      fake_response({ 'models' => [{ 'name' => 'qwen3.6:27b', 'details' => { 'family' => 'qwen35' } }] })
    )
    allow(provider.connection).to receive(:get).with('/api/ps').and_return(
      fake_response({ 'models' => [] })
    )

    offerings = provider.discover_offerings(live: true)

    expect(offerings.first.metadata[:loaded]).to be(false)
  end

  it 'builds sanitized lex-llm registry events for Ollama model availability' do
    events = capture_registry_events([nomic_embed_model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:ollama)
    expect(events.first.to_h.dig(:offering, :usage_type)).to eq(:embedding)
    expect(events.first.to_h.dig(:offering, :model)).to eq('nomic-embed-text:latest')
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive_messages(socket_open?: false, setting: nil)
    end

    it 'normalizes configured instance endpoint aliases to base_url' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :ollama, :instances)
        .and_return({ lab: { endpoint: 'http://lab:11434' } })

      expect(described_class.discover_instances[:lab]).to include(
        base_url: 'http://lab:11434',
        tier: :direct,
        capabilities: %i[completion embedding vision]
      )
    end
  end

  it 'uses instance base_url config before provider defaults' do
    configured = described_class::Provider.new(base_url: 'http://configured:11434')

    expect(configured.api_base).to eq('http://configured:11434')
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

  def parse_models(body)
    provider.send(:parse_list_models_response, fake_response(body), :ollama, nil)
  end

  def nomic_embed_model
    Legion::Extensions::Llm::Model::Info.new(
      id: 'nomic-embed-text:latest',
      name: 'nomic-embed-text:latest',
      provider: :ollama,
      family: 'nomic-bert',
      capabilities: [:embedding],
      modalities_output: [:embeddings],
      metadata: { 'details' => { 'family' => 'nomic-bert', 'parameter_size' => '137M' } }
    )
  end

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('/api/tags').and_return(
      fake_response({ 'models' => [{ 'name' => 'qwen3.6:27b', 'details' => { 'family' => 'qwen35' } }] })
    )
    allow(provider.connection).to receive(:get).with('/api/ps').and_return(
      fake_response({ 'models' => [{ 'name' => 'qwen3.6:27b' }] })
    )
  end

  def stub_cached_offering_failure
    stub_model_discovery
    provider.discover_offerings(live: true)
    allow(provider).to receive(:offering_from_model).and_raise('broken cached model')
  end

  def stub_registry_publisher
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_readiness_async)
    allow(registry_publisher).to receive(:publish_models_async)
  end

  def capture_registry_events(models, readiness:)
    publisher = Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :ollama)
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
