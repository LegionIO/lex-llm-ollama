# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/ollama/runners/discovery'

# Lifecycle coverage for the SSOT discovery pass on the provider's runner
# module: multi-instance claim/activate, D3 unconfigured-phantom handling,
# D4 initial-failure recovery, tick reconcile, D9 cadence (base actor),
# D14 display health, no replace churn, D16 loud programming errors, and
# teardown. The probe and model-fetch boundaries are stubbed on the runner
# module so the registry state machine runs offline; discovery reads and
# D14 writes go through the live Legion::Settings tree (same as production).
# Generic pipeline internals (reconcile/claim/probe/replace ownership) are
# the shared Discovery::Pipeline's, covered in lex-llm — this spec keeps the
# Ollama provider-specific slice (config-name identity, /api/tags boundaries,
# D9/D14/D16 behavior on this provider's runner).
RSpec.describe Legion::Extensions::Llm::Ollama::Runners::Discovery do
  # let (not subject) so the boundary stubs below are not flagged as stubbing
  # the object under test.
  let(:runner) { described_class }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:settings_tree) { Legion::Settings.loader.settings[:extensions][:llm][:ollama] }
  let(:synthetic_default) { Legion::Extensions::Llm::Ollama.default_settings.dig(:instances, :default) }

  before do
    registry.reset!
    # The runner module carries process-local working state (states) that
    # outlives registry.reset!; drop it for a fresh pass per example.
    described_class.reset_state!
  end

  after { settings_tree.clear }

  def key_for(instance_id, physical_id: nil)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :ollama, instance_id: instance_id, physical_id: physical_id
    )
  end

  def readiness(ready:, reason:)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: ready, reason: reason)
  end

  def healthy = readiness(ready: true, reason: 'Ollama /api/tags returned 200')
  def unhealthy = readiness(ready: false, reason: 'Ollama /api/tags connection failed')

  # Boundary stubs: the runner builds its own Faraday connections per
  # probe/fetch, so the probe + model-fetch boundary is stubbed on the
  # runner module (there is no injectable seam at the connection level).
  def stub_boundaries(readiness_result:, models: [{ name: 'qwen3:8b', digest: 'sha256:specdigest' }])
    allow(described_class).to receive_messages(
      check_health: readiness_result,
      fetch_model_detail_safe: nil,
      fetch_raw_models: models
    )
  end

  def configure_instances(instances)
    settings_tree[:instances] = instances
  end

  def instance_ids
    registry.snapshot.each_instance.map { |record| record.instance_key.instance_id }
  end

  # ── D3: only operator-configured instances are registered ──────────────────

  describe 'unconfigured phantom handling (D3)' do
    it 'registers the default instance when it is present' do
      configure_instances(default: synthetic_default)
      stub_boundaries(readiness_result: healthy)

      runner.refresh

      expect(instance_ids).to eq(['default'])
    end

    it 'claims a named instance alongside the default instance' do
      configure_instances(
        default: synthetic_default,
        alpha: { base_url: 'http://127.0.0.1:11435', tier: :local }
      )
      stub_boundaries(readiness_result: healthy)

      runner.refresh

      expect(instance_ids).to contain_exactly('alpha', 'default')
    end

    it 'keeps the discovery pass alive when the foundation rejects the configured default claim' do
      # The provider layer passes a configured (non-template) instances.default
      # to the claim path (v2 parity). Whether the foundation accepts the name
      # is a lex-llm InstanceKey contract, not a provider-layer decision:
      # under the current lex-llm floor the claim raises, the pipeline logs it,
      # and the rest of the pass still runs — a claim failure for one
      # instance must not poison the others.
      configure_instances(
        default: synthetic_default.merge(base_url: 'http://127.0.0.1:11500'),
        alpha: { base_url: 'http://127.0.0.1:11435', tier: :local }
      )
      stub_boundaries(readiness_result: healthy)

      runner.refresh

      expect(instance_ids).to include('alpha')
    end

    it 'skips disabled and endpoint-less instances' do
      configure_instances(
        off: { base_url: 'http://127.0.0.1:11435', enabled: false },
        bare: { tier: :local }
      )
      stub_boundaries(readiness_result: healthy)

      runner.refresh

      expect(instance_ids).to be_empty
    end

    it 'discovers multiple configured instances with per-instance readiness' do
      configure_instances(
        alpha: { base_url: 'http://127.0.0.1:11435', tier: :local },
        beta: { base_url: 'http://127.0.0.1:11436', tier: :local }
      )
      up = key_for('alpha', physical_id: '127.0.0.1:11435')
      down = key_for('beta', physical_id: '127.0.0.1:11436')
      allow(described_class).to receive(:check_health) do |instance_cfg:|
        instance_cfg[:base_url].end_with?('11435') ? healthy : unhealthy
      end
      allow(described_class).to receive_messages(fetch_model_detail_safe: nil,
                                                 fetch_raw_models: [{ name: 'qwen3:8b' }])

      runner.refresh

      expect(registry.snapshot.instance(instance_key: up).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: down).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: down)).to be_nil
    end
  end

  # ── Identity = config name (derived host:port is the secondary physical id) ─

  describe 'config-name identity' do
    before do
      stub_boundaries(readiness_result: healthy)
    end

    it 'publishes the config name as instance_id and the derived host:port as physical_id' do
      configure_instances(apollo: { base_url: 'http://127.0.0.1:11435', tier: :local })

      runner.refresh

      record = registry.snapshot.instance(instance_key: key_for('apollo', physical_id: '127.0.0.1:11435'))
      expect(record.instance_key.instance_id).to eq('apollo')
      expect(record.instance_key.physical_id).to eq('127.0.0.1:11435')
    end

    it 'registers two config names pointing at the same endpoint as distinct instances' do
      configure_instances(
        apollo: { base_url: 'http://127.0.0.1:11435', tier: :local },
        apollo_embed: { base_url: 'http://127.0.0.1:11435', tier: :local }
      )

      runner.refresh

      expect(instance_ids.sort).to eq(%w[apollo apollo_embed])
    end
  end

  # ── D4: recovery after initial readiness failure ───────────────────────────

  describe 'initial readiness failure recovery (D4)' do
    before do
      configure_instances(alpha: { base_url: 'http://127.0.0.1:11435', tier: :local })
      allow(described_class).to receive_messages(fetch_model_detail_safe: nil,
                                                 fetch_raw_models: [{ name: 'qwen3:8b' }])
    end

    it 'activates the instance on a later tick once readiness passes' do
      allow(described_class).to receive(:check_health).and_return(unhealthy, healthy)

      runner.refresh # initial discovery: claim + readiness FAILED

      key = key_for('alpha', physical_id: '127.0.0.1:11435')
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      runner.refresh # tick: retry initial activation → readiness passes → activate

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end

    it 'stays initializing while readiness keeps failing' do
      allow(described_class).to receive(:check_health).and_return(unhealthy)

      runner.refresh
      runner.refresh
      runner.refresh

      key = key_for('alpha', physical_id: '127.0.0.1:11435')
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # ── D4/tick reconcile: late-configured and removed instances ────────────────

  describe 'tick reconciliation' do
    it 'adds instances that appear in settings after boot and removes ones that disappear' do
      stub_boundaries(readiness_result: healthy)

      configure_instances(alpha: { base_url: 'http://127.0.0.1:11435', tier: :local })
      runner.refresh
      expect(instance_ids).to eq(['alpha'])

      configure_instances(beta: { base_url: 'http://127.0.0.1:11436', tier: :local })
      runner.refresh
      # Late instance claimed, removed instance retired.
      expect(instance_ids).to eq(['beta'])
    end
  end

  # ── No replace churn when the model set is unchanged ────────────────────────

  describe 'snapshot replace churn' do
    before do
      configure_instances(alpha: { base_url: 'http://127.0.0.1:11435', tier: :local })
    end

    it 'does not replace the snapshot when the model set and evidence are unchanged' do
      # Fresh drafts with fresh observed_at on every call — Data#== would say
      # "changed" every tick; the signature compare must not.
      stub_boundaries(readiness_result: healthy)

      runner.refresh # initial activate (sequence 0)
      runner.refresh # tick 1
      runner.refresh # tick 2

      key = key_for('alpha', physical_id: '127.0.0.1:11435')
      # Unchanged offerings must not bump the publication sequence.
      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(0)
    end

    it 'replaces the snapshot when the model set actually changes' do
      allow(described_class).to receive_messages(check_health: healthy, fetch_model_detail_safe: nil)
      allow(described_class).to receive(:fetch_raw_models)
        .and_return([{ name: 'qwen3:8b' }],
                    [{ name: 'qwen3:8b' }, { name: 'llama3.1:8b' }])

      runner.refresh # initial activate with one model
      runner.refresh # tick: second model appears → replace

      key = key_for('alpha', physical_id: '127.0.0.1:11435')
      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(1)
      expect(registry.snapshot.lanes_for(instance_key: key).size).to eq(2)
    end
  end

  # ── D9: actor periodicity (base actor, shared by every provider) ────────────

  describe 'tick interval (time)' do
    subject(:actor) { Legion::Extensions::Llm::Ollama::Actor::Discovery.new }

    it 'returns the registered discovery interval (never nil)' do
      settings_tree[:discovery] = { interval_seconds: 300 }
      expect(actor.time).to eq(300)
    end

    it 'honors an operator override of the interval' do
      settings_tree[:discovery] = { interval_seconds: 60 }
      expect(actor.time).to eq(60)
    end

    it 'falls back to the registered default when the interval is missing or non-positive' do
      expect(actor.time).to be_a(Integer).and be_positive

      settings_tree[:discovery] = { interval_seconds: 0 }
      expect(actor.time).to be_a(Integer).and be_positive

      settings_tree[:discovery] = { interval_seconds: nil }
      expect(actor.time).to be_a(Integer).and be_positive
    end
  end

  # ── D14: settings display health after registry commits ────────────────────

  describe 'settings display health (D14)' do
    before do
      configure_instances(alpha: { base_url: 'http://127.0.0.1:11435', tier: :local })
      allow(described_class).to receive_messages(fetch_model_detail_safe: nil,
                                                 fetch_raw_models: [{ name: 'qwen3:8b' }])
    end

    it 'writes the 5-key health shape plus capabilities after each registry commit' do
      allow(described_class).to receive(:check_health).and_return(unhealthy, healthy)

      runner.refresh # initial failure

      health = settings_tree.dig(:instances, :alpha, :health)
      expect(health).to include(state: :initializing, source: :startup_readiness)
      expect(health[:last_probe_outcome]).to eq(:failure)
      expect(health[:reason]).to be_a(String)
      # 0.8.0 health hash: observed_at is Time#iso8601 of the probe
      # completion (host-local offset, not the legacy Z/millis writer).
      expect(health[:observed_at]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
      # No lanes are published until activation — the capability union is
      # over activated lanes only.
      expect(settings_tree.dig(:instances, :alpha, :capabilities)).to eq([])

      runner.refresh # recovery → activate

      health = settings_tree.dig(:instances, :alpha, :health)
      expect(health).to include(state: :available)
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(settings_tree.dig(:instances, :alpha, :capabilities)).to include(:completion, :streaming)
    end

    it 'keys the health hash by the config name, not the derived instance_id' do
      allow(described_class).to receive(:check_health).and_return(healthy)

      runner.refresh

      expect(settings_tree[:instances].keys).to include(:alpha)
      expect(settings_tree[:instances].keys).not_to include('127.0.0.1:11435')
      expect(settings_tree.dig(:instances, :alpha, :health)[:state]).to eq(:available)
    end

    it 'clears the health hash when the instance is removed' do
      allow(described_class).to receive(:check_health).and_return(healthy)

      runner.refresh
      expect(settings_tree.dig(:instances, :alpha, :health)).not_to be_nil

      runner.remove_all_instances
      expect(settings_tree.dig(:instances, :alpha, :health)).to be_nil
      expect(settings_tree.dig(:instances, :alpha, :capabilities)).to be_nil
      expect(registry.snapshot.instance(instance_key: key_for('alpha', physical_id: '127.0.0.1:11435'))).to be_nil
    end
  end

  # ── Shutdown ────────────────────────────────────────────────────────────────

  describe 'shutdown' do
    it 'retires all instances and clears their display health' do
      configure_instances(
        alpha: { base_url: 'http://127.0.0.1:11435', tier: :local },
        beta: { base_url: 'http://127.0.0.1:11436', tier: :local }
      )
      stub_boundaries(readiness_result: healthy)

      runner.refresh
      expect(instance_ids.size).to eq(2)

      runner.remove_all_instances

      expect(instance_ids).to be_empty
      expect(registry.snapshot.each_publication_status.to_a).to be_empty
    end
  end

  # ── D16: programming errors fail loud, transport failures defer ─────────────

  describe 'offering discovery error handling (D16)' do
    # Plain methods (not lets) to stay under RSpec/MultipleMemoizedHelpers.
    def d16_instance_cfg = { base_url: 'http://127.0.0.1:11435', tier: :local }
    def d16_instance_key = key_for('alpha', physical_id: '127.0.0.1:11435')

    it 'propagates programming errors instead of publishing an empty offering set' do
      allow(described_class).to receive(:fetch_raw_models).and_return([{ name: 'qwen3:8b' }])
      allow(described_class).to receive(:build_offering_draft).and_raise(NameError, 'unresolved constant')

      expect do
        described_class.build_offerings(instance_cfg: d16_instance_cfg, instance_key: d16_instance_key)
      end.to raise_error(NameError)
    end

    it 'raises CatalogFetchFailure for transport failures (callers keep the last snapshot)' do
      allow(described_class).to receive(:fetch_raw_models)
        .and_raise(Faraday::ConnectionFailed.new('connection refused'))

      expect do
        described_class.build_offerings(instance_cfg: d16_instance_cfg, instance_key: d16_instance_key)
      end.to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure)
    end
  end
end
