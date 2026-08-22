# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/ollama/runners/discovery'

RSpec.describe Legion::Extensions::Llm::Ollama do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  # The render funnel takes a RAW STRING model (0.8.0 model type deleted).
  let(:qwen_model) { 'qwen3.6:27b' }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  it 'exposes provider defaults with the full settings schema' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings).to include(enabled: true, provider_family: :ollama)
    expect(instance).to include(endpoint: 'http://127.0.0.1:11434', tier: :local, transport: :http)
    expect(instance).not_to have_key(:default_model)
    expect(instance).to include(fleet: hash_including(respond_to_requests: false))
    expect(instance[:usage]).to include(inference: true)
    expect(instance[:usage]).not_to have_key(:embedding)
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
    expect(payload[:options]).to eq(temperature: 0.2)
  end

  it 'parses current and legacy Ollama embedding responses into the 05 §3 artifact' do
    # Single text input: the embeddings array's first vector is the result;
    # Array input keeps the full vector list.
    current = embedding_for({ 'embeddings' => [[0.1, 0.2]], 'prompt_eval_count' => 3 })
    legacy = embedding_for({ 'embedding' => [0.3, 0.4] })
    multi = embedding_for({ 'embeddings' => [[0.1], [0.2]] }, text: %w[one two])

    expect(current[:embedding]).to eq([0.1, 0.2])
    expect(current[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    expect(current[:usage].input_tokens).to eq(3)
    expect(legacy[:embedding]).to eq([0.3, 0.4])
    expect(legacy[:model]).to eq('nomic-embed-text')
    expect(legacy).not_to have_key(:usage)
    expect(multi[:embedding]).to eq([[0.1], [0.2]])
  end

  it 'renders embedding payloads with model ids' do
    payload = provider.send(:render_embedding_payload, 'hello', model: 'nomic-embed-text:latest', dimensions: nil)

    expect(payload).to eq(model: 'nomic-embed-text:latest', input: 'hello')
  end

  it 'does not probe Ollama for uncached non-live offerings reads' do
    # The read path serves the Registry snapshot only — with no activated
    # instance there is nothing to serve and no live probe.
    registry.reset!
    expect(provider.discover_offerings).to eq([])
  ensure
    registry.reset!
  end

  # 07 C5: the provider read path serves the activated inventory offerings
  # from Registry.snapshot; the SSOT discovery actor is the sole publication
  # path (no live provider-side offering construction in 0.8.0).
  describe 'registry-snapshot offerings read path' do
    before { registry.reset! }
    after { registry.reset! }

    def activate_snapshot_instance(tier: :local)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: 'default'
      )
      runner = Legion::Extensions::Llm::Ollama::Runners::Discovery
      allow(runner).to receive(:fetch_model_detail_safe).and_return(nil)
      draft = runner.build_offering_draft(
        model_id: 'qwen3.6:27b',
        model_data: { name: 'qwen3.6:27b', digest: 'sha256:specdigest' },
        instance_cfg: { base_url: 'http://127.0.0.1:11435', tier: tier },
        instance_key: key
      )

      callable = Legion::Extensions::Llm::Ollama::Helpers::Callable.new(
        instance_cfg: { base_url: 'http://127.0.0.1:11435' }, logger: Logger.new(File::NULL)
      )
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      token = publisher.claim_instance(
        instance_id: 'default', callable: callable, probe_request_handle: coordinator
      )
      probe = publisher.readiness_probe_started(instance_id: 'default', publisher_token: token)
      publisher.activate_instance_snapshot(
        instance_id: 'default', publisher_token: token, offerings: [draft], sequence: 0, probe_token: probe
      )
    end

    it 'serves the activated offerings for the provider instance' do
      activate_snapshot_instance

      offerings = provider.discover_offerings

      expect(offerings.map(&:model)).to eq(['qwen3.6:27b'])
      expect(offerings.first.tier).to eq(:local)
    end

    it 'honors the draft tier on the served offerings' do
      activate_snapshot_instance(tier: :frontier)

      expect(provider.discover_offerings.first.tier).to eq(:frontier)
    end

    it 'filters served offerings by model' do
      activate_snapshot_instance

      expect(provider.discover_offerings(model: 'qwen3.6:27b').map(&:model)).to eq(['qwen3.6:27b'])
      expect(provider.discover_offerings(model: 'llama3.1:8b')).to be_empty
    end
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(nil)
    end

    it 'normalizes configured instance endpoint aliases to base_url' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :ollama, :instances)
        .and_return({ lab: { endpoint: 'http://lab:11434' } })

      expect(described_class.discover_instances[:lab]).to include(
        base_url: 'http://lab:11434',
        tier: :local,
        capabilities: {},
        provider_capabilities: { streaming: true }
      )
    end
  end

  it 'uses instance base_url config before provider defaults' do
    configured = described_class::Provider.new(base_url: 'http://configured:11434')

    expect(configured.api_base).to eq('http://configured:11434')
  end

  def chat_payload
    message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2)
    thinking = Legion::Extensions::Llm::Canonical::Thinking::Config.build(effort: 'medium')
    provider.send(:render_payload, [message], tools: {}, params: params, model: qwen_model, stream: false,
                                              schema: nil, thinking: thinking, tool_prefs: nil)
  end

  def embedding_for(body, text: 'hello')
    provider.send(:parse_embedding_response, fake_response(body), model: 'nomic-embed-text', text: text)
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end
end
