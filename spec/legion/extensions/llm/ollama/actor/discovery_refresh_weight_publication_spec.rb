# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::Ollama::Actor::DiscoveryRefresh do
  let(:actor) { described_class.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:root_settings) { Legion::Settings.loader.settings }
  let(:provider_settings) { root_settings[:extensions][:llm][:ollama] }

  before do
    registry.reset!
    @previous_llm_settings = root_settings[:llm]
    root_settings[:llm] = { routing: { tier_weights: { local: 140 } } }
    provider_settings.clear
  end

  after do
    provider_settings.clear
    root_settings[:llm] = @previous_llm_settings
  end

  def healthy
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'ready')
  end

  def unhealthy
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: false, reason: 'down')
  end

  def configure_alpha(weight: nil, models: nil)
    instance = { base_url: 'http://127.0.0.1:11435', tier: :local }
    instance[:weight] = weight unless weight.nil?
    instance[:models] = models unless models.nil?
    provider_settings[:instances] = { alpha: instance }
  end

  def stub_catalog(readiness_result: healthy, model: 'qwen3:8b')
    allow(actor).to receive_messages(
      check_readiness: readiness_result,
      fetch_model_detail_safe: nil,
      fetch_models: [{ name: model, digest: 'sha256:weight-spec' }]
    )
  end

  def alpha_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :ollama,
      instance_id: 'alpha',
      physical_id: '127.0.0.1:11435'
    )
  end

  def alpha_state
    actor.instance_variable_get(:@instance_states)[:alpha]
  end

  def alpha_offering
    registry.snapshot.offerings_for(instance_key: alpha_key).first
  end

  def build_draft(model: 'qwen3:8b')
    allow(actor).to receive(:fetch_model_detail_safe).and_return(nil)
    actor.send(
      :build_offering_draft,
      model_name: model,
      model_data: { name: model, digest: 'sha256:weight-spec' },
      instance_cfg: provider_settings[:instances][:alpha],
      instance_key: alpha_key
    )
  end

  def authoritative_contract_variant(draft, field)
    case field
    when :quota_domains
      draft.with(quota_domains: { chat: 'ollama-chat-v2' })
    when :metadata
      draft.with(metadata: draft.metadata.merge(catalog_revision: 'v2'))
    when :publication_source
      draft.with(publication_source: :provider_control_plane)
    when :context_evidence
      draft.with(context_evidence: draft.context_evidence.with(source: :default_false))
    end
  end

  describe 'write-time weights on the ordinary discovery cadence' do
    it 'stores the exact four-axis pair and product on each constructed draft' do
      provider_settings[:weight] = 110
      provider_settings[:models] = { 'qwen3:8b' => { weight: 125 } }
      configure_alpha(weight: 115)

      draft = build_draft

      expect(draft.weight_inputs).to eq(
        tier: 140,
        provider: 110,
        instance: 115,
        model_or_offering: 125
      )
      expect(draft.base_weight).to eq(221_375_000)
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      provider_settings[:weight] = 110
      configure_alpha
      stub_catalog

      actor.manual
      provider_settings[:weight] = 120
      actor.manual

      status = registry.snapshot.publication_status(instance_key: alpha_key)
      expect(status.published_sequence).to eq(1)
      expect(alpha_offering.weight_inputs[:provider]).to eq(120)
      expect(alpha_offering.base_weight).to eq(168_000_000)
      expect(actor).to have_received(:fetch_models).twice
      expect(actor).to have_received(:check_readiness).twice
    end

    it 'publishes nothing when settings change without changing the weight pair' do
      configure_alpha
      stub_catalog

      actor.manual
      provider_settings[:unrelated_display_option] = 'changed'
      actor.manual

      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
    end

    it 'stores an explicit zero component without applying the identity default' do
      provider_settings[:weight] = 0
      configure_alpha
      stub_catalog

      actor.manual

      expect(alpha_offering.weight_inputs[:provider]).to eq(0)
      expect(alpha_offering.base_weight).to eq(0)
    end

    it 'raises for a malformed false component instead of silently defaulting it' do
      provider_settings[:weight] = false
      configure_alpha

      expect { build_draft }.to raise_error(ArgumentError, /weight component must be an Integer >= 0/)
    end

    it 'does not claim or construct a callable until startup weights validate' do
      provider_settings[:weight] = false
      configure_alpha
      stub_catalog
      publisher = actor.send(:publisher)
      callable_class = Legion::Extensions::Llm::Ollama::Actor::OllamaCallable
      allow(publisher).to receive(:claim_instance).and_call_original
      allow(callable_class).to receive(:new).and_call_original

      actor.manual

      expect(registry.snapshot.publication_status(instance_key: alpha_key)).to be_nil
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(actor.instance_variable_get(:@instance_states)).to be_empty
      expect(publisher).not_to have_received(:claim_instance)
      expect(callable_class).not_to have_received(:new)

      provider_settings[:weight] = 110
      actor.manual

      expect(publisher).to have_received(:claim_instance).once
      expect(callable_class).to have_received(:new).once
      expect(registry.snapshot.publication_status(instance_key: alpha_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: alpha_key).availability.state).to eq(:available)
      expect(actor.instance_variable_get(:@instance_states).keys).to eq([:alpha])
    end

    it 'keeps sequence zero across ten unchanged ordinary passes' do
      configure_alpha
      stub_catalog

      actor.manual
      10.times { actor.manual }

      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
      expect(alpha_state[:sequence]).to eq(0)
    end

    %i[quota_domains metadata publication_source context_evidence].each do |field|
      it "publishes one Registry replacement for an authoritative #{field} change" do
        configure_alpha
        stub_catalog
        actor.manual
        previous = alpha_state.fetch(:offerings)
        changed = previous.dup
        changed[0] = authoritative_contract_variant(previous.first, field)
        allow(actor).to receive(:discover_offerings_for_instance).and_return(changed)
        publisher = actor.send(:publisher)
        allow(publisher).to receive(:replace_instance_snapshot).and_call_original

        actor.manual

        published = registry.snapshot.offerings_for(instance_key: alpha_key)
                            .find { |offering| offering.model == changed.first.model }
        expect(publisher).to have_received(:replace_instance_snapshot).once
        expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(1)
        expect(alpha_state[:sequence]).to eq(1)
        expect(published.public_send(field)).to eq(changed.first.public_send(field))
      end
    end

    it 'does not replace an equivalent two-offering catalog returned in reverse order' do
      configure_alpha
      allow(actor).to receive_messages(check_readiness: healthy, fetch_model_detail_safe: nil)
      catalog = [
        { name: 'qwen3:8b', digest: 'sha256:qwen' },
        { name: 'llama3.1:8b', digest: 'sha256:llama' }
      ]
      allow(actor).to receive(:fetch_models).and_return(catalog, catalog.reverse)
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      actor.manual
      actor.manual

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
      expect(alpha_state[:sequence]).to eq(0)
    end

    it 'treats duplicate offering multiplicity as a significant ordinary-cadence change' do
      configure_alpha
      allow(actor).to receive_messages(check_readiness: healthy, fetch_model_detail_safe: nil)
      catalog = [
        { name: 'qwen3:8b', digest: 'sha256:qwen' },
        { name: 'llama3.1:8b', digest: 'sha256:llama' }
      ]
      allow(actor).to receive(:fetch_models).and_return(catalog, catalog + [catalog.first])
      publisher = actor.send(:publisher)
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot) { |**kwargs| replacements << kwargs }

      actor.manual
      actor.manual

      expect(replacements.length).to eq(1)
      expect(replacements.first.fetch(:offerings).length).to eq(3)
      expect(alpha_state[:sequence]).to eq(1)
    end

    it 'logs each dormant model once, clears it on appearance, and logs its re-disappearance' do
      output = StringIO.new
      allow(actor).to receive(:log).and_return(Logger.new(output))
      provider_settings[:models] = { ghost: { weight: 125 } }
      provider_settings[:instances] = {}
      stub_catalog(model: 'ghost')

      actor.manual
      actor.manual
      configure_alpha
      provider_settings[:models] = { ghost: { weight: 125 } }
      actor.manual
      provider_settings[:instances] = {}
      actor.manual

      dormant_lines = output.string.lines.grep(/\[llm\]\[ollama\] action=dormant_weight/)
      expect(dormant_lines.size).to eq(2)
      expect(dormant_lines).to all(include('weight_key=[:ollama, :model, "ghost"]'))
    end

    it 'never couples its ordinary pass or shutdown to Settings lifecycle methods' do
      configure_alpha
      stub_catalog
      allow(Legion::Settings).to receive(:on_reload).and_call_original
      allow(Legion::Settings).to receive(:reload!).and_call_original
      allow(Legion::Settings).to receive(:reset!).and_call_original

      actor.manual
      actor.manual
      actor.shutdown

      expect(Legion::Settings).not_to have_received(:on_reload)
      expect(Legion::Settings).not_to have_received(:reload!)
      expect(Legion::Settings).not_to have_received(:reset!)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
    end

    it 'serializes concurrent passes to at most one replacement per weight value' do
      configure_alpha
      stub_catalog
      actor.manual

      sequences = (101..110).map do |weight|
        provider_settings[:weight] = weight
        threads = Array.new(2) { Thread.new { actor.send(:replace_offerings_if_changed, state: alpha_state) } }
        threads.each(&:join)
        registry.snapshot.publication_status(instance_key: alpha_key).published_sequence
      end

      expect(sequences).to eq((1..10).to_a)
      expect(alpha_state[:sequence]).to eq(10)
      expect(alpha_state[:offerings].first.base_weight).to eq(alpha_offering.base_weight)
      expect(alpha_offering.weight_inputs[:provider]).to eq(110)
    end

    it 'leaves the cache unchanged after replacement failure and retries on the next pass' do
      provider_settings[:weight] = 110
      configure_alpha
      stub_catalog
      actor.manual
      original = actor.send(:publisher).method(:replace_instance_snapshot)
      attempts = 0
      allow(actor.send(:publisher)).to receive(:replace_instance_snapshot) do |**kwargs|
        attempts += 1
        raise 'publisher unavailable' if attempts == 1

        original.call(**kwargs)
      end
      provider_settings[:weight] = 120

      actor.manual

      expect(alpha_state[:sequence]).to eq(0)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(110)

      actor.manual

      expect(alpha_state[:sequence]).to eq(1)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)
      expect(alpha_offering.weight_inputs[:provider]).to eq(120)
    end
  end

  describe 'two-phase initial publication' do
    it 'rebuilds from current settings after a weight changes during readiness' do
      provider_settings[:weight] = 110
      configure_alpha
      allow(actor).to receive_messages(fetch_model_detail_safe: nil,
                                       fetch_models: [{ name: 'qwen3:8b' }])
      readiness_started = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_readiness) do
        readiness_started << true
        resume_readiness.pop
        healthy
      end

      thread = Thread.new { actor.manual }
      readiness_started.pop
      provider_settings[:weight] = 120
      resume_readiness << true
      thread.join

      expect(alpha_offering.weight_inputs[:provider]).to eq(120)
      expect(alpha_state[:offerings].first.base_weight).to eq(168_000_000)
      expect(alpha_state[:published]).to be(true)
    end

    it 'updates an unpublished cache without replacing or satisfying dormant matching' do
      output = StringIO.new
      allow(actor).to receive(:log).and_return(Logger.new(output))
      provider_settings[:weight] = 110
      provider_settings[:models] = { 'qwen3:8b' => { weight: 125 } }
      configure_alpha
      provider_settings[:models] = { 'qwen3:8b' => { weight: 125 } }
      stub_catalog(readiness_result: unhealthy)

      actor.manual
      provider_settings[:weight] = 120
      actor.manual

      expect(alpha_state).to include(sequence: 0, published: false)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(output.string.lines.grep(/weight_key=\[:ollama, :model, "qwen3:8b"\]/).size).to eq(1)
    end

    it 'does not resurrect a tracked state removed while readiness is in flight' do
      configure_alpha
      allow(actor).to receive_messages(fetch_model_detail_safe: nil,
                                       fetch_models: [{ name: 'qwen3:8b' }])
      readiness_started = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_readiness) do
        readiness_started << true
        resume_readiness.pop
        healthy
      end

      thread = Thread.new { actor.manual }
      readiness_started.pop
      actor.shutdown
      resume_readiness << true
      thread.join

      expect(actor.instance_variable_get(:@instance_states)).to be_empty
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(provider_settings.dig(:instances, :alpha, :health)).to be_nil
      expect(provider_settings.dig(:instances, :alpha, :capabilities)).to be_nil
    end

    it 'preserves initializing state after activation failure and retries successfully' do
      provider_settings[:weight] = 110
      configure_alpha
      allow(actor).to receive_messages(fetch_model_detail_safe: nil,
                                       fetch_models: [{ name: 'qwen3:8b' }])
      allow(actor).to receive(:check_readiness) do
        provider_settings[:weight] = 120
        healthy
      end
      original = actor.send(:publisher).method(:activate_instance_snapshot)
      attempts = 0
      allow(actor.send(:publisher)).to receive(:activate_instance_snapshot) do |**kwargs|
        attempts += 1
        raise 'activation unavailable' if attempts == 1

        original.call(**kwargs)
      end

      actor.manual

      expect(alpha_state).to include(sequence: 0, published: false)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(110)

      actor.manual

      expect(alpha_state).to include(sequence: 0, published: true)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)
      expect(alpha_offering.weight_inputs[:provider]).to eq(120)
    end
  end
end
