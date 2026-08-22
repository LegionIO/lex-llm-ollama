# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/ollama/runners/discovery'

# Weight-publication coverage for the SSOT discovery pass on the provider's
# runner module. Drafts are built identity-weighted by the provider; the
# shared WeightReconciler recomputes the write-time weight from live
# settings at publish, so the four-axis pair is asserted on the PUBLISHED
# LaneRecord, and malformed weights are asserted at the publish boundary
# (WeightSchema raises; refresh does not leak; the instance stays
# :initializing). The pipeline's generic weight machinery is the shared
# Discovery::Pipeline / WeightReconciler's, covered in lex-llm — this spec
# keeps the provider-specific slice (settings scopes this provider reads,
# publication through this provider's runner).
RSpec.describe Legion::Extensions::Llm::Ollama::Runners::Discovery do
  let(:runner) { described_class }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:root_settings) { Legion::Settings.loader.settings }
  let(:provider_settings) { root_settings[:extensions][:llm][:ollama] }

  before do
    registry.reset!
    # The runner module carries process-local working state (states) that
    # outlives registry.reset!; drop it for a fresh pass per example.
    described_class.reset_state!
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
    allow(described_class).to receive_messages(
      check_health: readiness_result,
      fetch_model_detail_safe: nil,
      fetch_raw_models: [{ name: model, digest: 'sha256:weight-spec' }]
    )
  end

  def alpha_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :ollama,
      instance_id: 'alpha',
      physical_id: '127.0.0.1:11435'
    )
  end

  # Pipeline working state: Concurrent::Map on the runner module, keyed by
  # the STRING config name.
  def alpha_state
    described_class.states['alpha']
  end

  def alpha_lane
    registry.snapshot.lanes_for(instance_key: alpha_key).first
  end

  def build_draft(model: 'qwen3:8b')
    allow(described_class).to receive(:fetch_model_detail_safe).and_return(nil)
    described_class.build_offering_draft(
      model_id: model,
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

  # The draft field maps onto the published lane field: the draft's
  # quota_domains Hash (per-operation) collapses to the lane's single
  # quota_domain (the representative operation's value — chat for the
  # inference lane).
  def lane_field(field)
    field == :quota_domains ? :quota_domain : field
  end

  def expected_lane_value(field, draft)
    field == :quota_domains ? draft.quota_domains[:chat] : draft.public_send(field)
  end

  describe 'write-time weights on the ordinary discovery cadence' do
    it 'builds identity-weighted drafts and stores the exact four-axis pair and product on the published lane' do
      provider_settings[:weight] = 110
      provider_settings[:models] = { 'qwen3:8b' => { weight: 125 } }
      configure_alpha(weight: 115)
      stub_catalog

      draft = build_draft
      # The provider computes NO weight — the raw draft is identity-weighted.
      expect(draft.weight_inputs).to eq(tier: 100, provider: 100, instance: 100, model_or_offering: 100)
      expect(draft.base_weight).to eq(100_000_000)

      runner.refresh

      # The WeightReconciler recomputes the pair from live settings at
      # publish; the lane stores it unchanged.
      expect(alpha_lane.weight_inputs).to eq(
        tier: 140,
        provider: 110,
        instance: 115,
        model_or_offering: 125
      )
      expect(alpha_lane.base_weight).to eq(221_375_000)
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      provider_settings[:weight] = 110
      configure_alpha
      stub_catalog

      runner.refresh
      provider_settings[:weight] = 120
      runner.refresh

      status = registry.snapshot.publication_status(instance_key: alpha_key)
      expect(status.published_sequence).to eq(1)
      expect(alpha_lane.weight_inputs[:provider]).to eq(120)
      expect(alpha_lane.base_weight).to eq(168_000_000)
      expect(described_class).to have_received(:fetch_raw_models).twice
      expect(described_class).to have_received(:check_health).twice
    end

    it 'publishes nothing when settings change without changing the weight pair' do
      configure_alpha
      stub_catalog

      runner.refresh
      provider_settings[:unrelated_display_option] = 'changed'
      runner.refresh

      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
    end

    it 'stores an explicit zero component without applying the identity default' do
      provider_settings[:weight] = 0
      configure_alpha
      stub_catalog

      runner.refresh

      expect(alpha_lane.weight_inputs[:provider]).to eq(0)
      expect(alpha_lane.base_weight).to eq(0)
    end

    it 'raises for a malformed false component instead of silently defaulting it' do
      provider_settings[:weight] = false
      configure_alpha

      draft = build_draft
      expect do
        Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
          settings: Legion::Settings,
          instance_key: alpha_key,
          model: draft.model,
          tier: draft.tier,
          operation_evidence: draft.operation_evidence
        )
      end.to raise_error(ArgumentError, /weight component must be an Integer >= 0/)
    end

    it 'blocks activation on a malformed startup weight without leaking out of refresh' do
      provider_settings[:weight] = false
      configure_alpha
      stub_catalog

      expect(runner.refresh).to eq({ success: true })

      # The claim stands (the instance is tracked), but the publish-boundary
      # weight failure keeps it :initializing — no activation, no leak.
      status = registry.snapshot.publication_status(instance_key: alpha_key)
      expect(status).not_to be_nil
      expect(status.state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(alpha_state.fetch(:published)).to be(false)

      provider_settings[:weight] = 110
      runner.refresh

      expect(registry.snapshot.publication_status(instance_key: alpha_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: alpha_key).availability.state).to eq(:available)
    end

    it 'keeps sequence zero across ten unchanged ordinary passes' do
      configure_alpha
      stub_catalog

      runner.refresh
      10.times { runner.refresh }

      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
      expect(alpha_state[:sequence]).to eq(0)
    end

    %i[quota_domains metadata publication_source context_evidence].each do |field|
      it "publishes one Registry replacement for an authoritative #{field} change" do
        configure_alpha
        stub_catalog
        runner.refresh
        previous = alpha_state.fetch(:offerings)
        changed = previous.dup
        changed[0] = authoritative_contract_variant(previous.first, field)
        allow(described_class).to receive(:build_offerings).and_return(changed)
        publisher = described_class.publisher
        allow(publisher).to receive(:replace_instance_snapshot).and_call_original

        runner.refresh

        published = registry.snapshot.lanes_for(instance_key: alpha_key)
                            .find { |lane| lane.model == changed.first.model }
        expect(publisher).to have_received(:replace_instance_snapshot).once
        expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(1)
        expect(alpha_state[:sequence]).to eq(1)
        expect(published.public_send(lane_field(field))).to eq(expected_lane_value(field, changed.first))
      end
    end

    it 'does not replace an equivalent two-offering catalog returned in reverse order' do
      configure_alpha
      allow(described_class).to receive_messages(check_health: healthy, fetch_model_detail_safe: nil)
      catalog = [
        { name: 'qwen3:8b', digest: 'sha256:qwen' },
        { name: 'llama3.1:8b', digest: 'sha256:llama' }
      ]
      allow(described_class).to receive(:fetch_raw_models).and_return(catalog, catalog.reverse)
      publisher = described_class.publisher
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      runner.refresh
      runner.refresh

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
      expect(alpha_state[:sequence]).to eq(0)
    end

    it 'treats duplicate offering multiplicity as a significant ordinary-cadence change' do
      configure_alpha
      allow(described_class).to receive_messages(check_health: healthy, fetch_model_detail_safe: nil)
      catalog = [
        { name: 'qwen3:8b', digest: 'sha256:qwen' },
        { name: 'llama3.1:8b', digest: 'sha256:llama' }
      ]
      allow(described_class).to receive(:fetch_raw_models).and_return(catalog, catalog + [catalog.first])
      publisher = described_class.publisher
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot) { |**kwargs| replacements << kwargs }

      runner.refresh
      runner.refresh

      # The pipeline comparison treats the multiplicity as a change and
      # emits the replacement (the publisher boundary is stubbed to
      # observe the emission; the sequence advances with it).
      expect(replacements.length).to eq(1)
      expect(replacements.first.fetch(:offerings).length).to eq(3)
      expect(alpha_state[:sequence]).to eq(1)
    end

    it 'logs each dormant model once, clears it on appearance, and logs its re-disappearance' do
      output = StringIO.new
      allow(described_class).to receive(:log).and_return(Logger.new(output))
      provider_settings[:models] = { ghost: { weight: 125 } }
      provider_settings[:instances] = {}
      stub_catalog(model: 'ghost')

      runner.refresh
      runner.refresh
      configure_alpha
      provider_settings[:models] = { ghost: { weight: 125 } }
      runner.refresh
      provider_settings[:instances] = {}
      runner.refresh

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

      runner.refresh
      runner.refresh
      runner.remove_all_instances

      expect(Legion::Settings).not_to have_received(:on_reload)
      expect(Legion::Settings).not_to have_received(:reload!)
      expect(Legion::Settings).not_to have_received(:reset!)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
    end

    it 'serializes concurrent passes to at most one replacement per weight value' do
      configure_alpha
      stub_catalog
      runner.refresh

      sequences = (101..110).map do |weight|
        provider_settings[:weight] = weight
        threads = Array.new(2) do
          Thread.new do
            described_class.replace_if_changed(
              instance_id: 'alpha', state: alpha_state, instance_cfg: provider_settings[:instances][:alpha]
            )
          end
        end
        threads.each(&:join)
        registry.snapshot.publication_status(instance_key: alpha_key).published_sequence
      end

      expect(sequences).to eq((1..10).to_a)
      expect(alpha_state[:sequence]).to eq(10)
      expect(alpha_state[:offerings].first.base_weight).to eq(alpha_lane.base_weight)
      expect(alpha_lane.weight_inputs[:provider]).to eq(110)
    end

    it 'leaves the cache unchanged after replacement failure and retries on the next pass' do
      provider_settings[:weight] = 110
      configure_alpha
      stub_catalog
      runner.refresh
      publisher = described_class.publisher
      original = publisher.method(:replace_instance_snapshot)
      attempts = 0
      allow(publisher).to receive(:replace_instance_snapshot) do |**kwargs|
        attempts += 1
        raise 'publisher unavailable' if attempts == 1

        original.call(**kwargs)
      end
      provider_settings[:weight] = 120

      runner.refresh

      expect(alpha_state[:sequence]).to eq(0)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(110)

      runner.refresh

      expect(alpha_state[:sequence]).to eq(1)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)
      expect(alpha_lane.weight_inputs[:provider]).to eq(120)
    end
  end

  describe 'two-phase initial publication' do
    it 'rebuilds from current settings after a weight changes during readiness' do
      provider_settings[:weight] = 110
      configure_alpha
      allow(described_class).to receive_messages(fetch_model_detail_safe: nil,
                                                 fetch_raw_models: [{ name: 'qwen3:8b' }])
      readiness_started = Queue.new
      resume_readiness = Queue.new
      allow(described_class).to receive(:check_health) do
        readiness_started << true
        resume_readiness.pop
        healthy
      end

      thread = Thread.new { runner.refresh }
      readiness_started.pop
      provider_settings[:weight] = 120
      resume_readiness << true
      thread.join

      expect(alpha_lane.weight_inputs[:provider]).to eq(120)
      expect(alpha_lane.base_weight).to eq(168_000_000)
      expect(alpha_state.fetch(:published)).to be(true)
    end

    it 'updates an unpublished cache without replacing or satisfying dormant matching' do
      output = StringIO.new
      allow(described_class).to receive(:log).and_return(Logger.new(output))
      provider_settings[:weight] = 110
      provider_settings[:models] = { 'qwen3:8b' => { weight: 125 } }
      configure_alpha
      stub_catalog(readiness_result: unhealthy)

      runner.refresh
      provider_settings[:weight] = 120
      runner.refresh

      expect(alpha_state).to include(sequence: 0, published: false)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(output.string.lines.grep(/weight_key=\[:ollama, :model, "qwen3:8b"\]/).size).to eq(1)
    end

    it 'does not resurrect a tracked state removed while readiness is in flight' do
      configure_alpha
      allow(described_class).to receive_messages(fetch_model_detail_safe: nil,
                                                 fetch_raw_models: [{ name: 'qwen3:8b' }])
      readiness_started = Queue.new
      resume_readiness = Queue.new
      allow(described_class).to receive(:check_health) do
        readiness_started << true
        resume_readiness.pop
        healthy
      end

      thread = Thread.new { runner.refresh }
      readiness_started.pop
      runner.remove_all_instances
      resume_readiness << true
      thread.join

      expect(described_class.states).to be_empty
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(provider_settings.dig(:instances, :alpha, :health)).to be_nil
      expect(provider_settings.dig(:instances, :alpha, :capabilities)).to be_nil
    end

    it 'preserves initializing state after activation failure and retries successfully' do
      provider_settings[:weight] = 110
      configure_alpha
      allow(described_class).to receive_messages(fetch_model_detail_safe: nil,
                                                 fetch_raw_models: [{ name: 'qwen3:8b' }])
      allow(described_class).to receive(:check_health) do
        provider_settings[:weight] = 120
        healthy
      end
      publisher = described_class.publisher
      original = publisher.method(:activate_instance_snapshot)
      attempts = 0
      allow(publisher).to receive(:activate_instance_snapshot) do |**kwargs|
        attempts += 1
        raise 'activation unavailable' if attempts == 1

        original.call(**kwargs)
      end

      runner.refresh

      expect(alpha_state).to include(sequence: 0, published: false)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(110)

      runner.refresh

      expect(alpha_state).to include(sequence: 0, published: true)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)
      expect(alpha_lane.weight_inputs[:provider]).to eq(120)
    end
  end
end
