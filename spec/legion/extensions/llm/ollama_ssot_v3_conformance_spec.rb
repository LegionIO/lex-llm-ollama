# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# OllamaCallable is loaded via spec_helper → ollama.rb → discovery_refresh.rb
# (spec_helper stubs the LegionIO actor runtime before loading ollama)

# ── RecordingOllamaProvider ───────────────────────────────────────────────────
# Test-local stand-in for the per-instance Ollama::Provider that the
# PRODUCTION OllamaCallable delegates its fleet dispatch ops to. It replaces
# the I/O boundary (the Provider's HTTP client) so conformance tests run
# offline; the callable under test is the real production class, and its
# dispatch methods are the real delegation code.
class RecordingOllamaProvider
  attr_reader :calls, :disconnected

  def initialize
    @calls = []
    @disconnected = false
  end

  def call_count = @calls.size

  # The production Ollama::Provider inherits enforce_canonical_messages!
  # from the lex-llm base (0.7.7); the OllamaCallable dispatch ops call it
  # before delegating. Delegate to the real implementation so the callable's
  # dispatch-boundary enforcement runs production code under test.
  def enforce_canonical_messages!(messages)
    base.enforce_canonical_messages!(messages)
  end

  # 0.8.0 callable contract: messages is the positional canonical Array.
  def chat(messages, model:, **rest)
    record(:chat, messages: messages, model: model, **rest)
    Legion::Extensions::Llm::Canonical::Response.build(text: 'test response', model: model, stop_reason: :end_turn)
  end

  def stream_chat(messages, model:, **rest, &blk)
    record(:stream_chat, messages: messages, model: model, **rest)
    blk&.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: 'streamed response', request_id: nil))
    blk&.call(Legion::Extensions::Llm::Canonical::Chunk.done(request_id: nil))
    nil
  end

  def embed(text:, model:, **rest)
    record(:embed, text: text, model: model, **rest)
    { text: text, model: model, embedding: [0.1, 0.2, 0.3] }
  end

  def count_tokens(messages:, model:, **rest)
    record(:count_tokens, messages: messages, model: model, **rest)
    { token_count: 42, model: model }
  end

  def disconnect
    @disconnected = true
  end

  private

  def base
    @base ||= Legion::Extensions::Llm::Ollama::Provider.new({})
  end

  def record(operation, **args)
    @calls << { operation: operation, **args }
  end
end

# Synthetic error used only for the SSOT v3 contract test that verifies
# instance isolation. Ollama has no wire-level instance_unavailable dispatch
# signal (a dead server drops the connection — the :connection_failure
# down-signal the readiness probe turns into an availability transition);
# this class exercises the shared contract example with the one outcome kind
# that performs the global transition.
class OllamaExplicitServiceGoneSignal < StandardError; end

# ── OllamaSsotHarness ─────────────────────────────────────────────────────────
# Harness class for Ollama SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching any
# external service. build_callable returns the PRODUCTION OllamaCallable
# (dispatch ops delegate to an injected RecordingOllamaProvider in place of
# the real per-instance Provider's HTTP client), and identity/draft building
# delegate to the PRODUCTION methods — the harness duplicates no builder
# logic (drift would mask production bugs).
class OllamaSsotHarness
  # The config NAME is the operator's identity (InstanceKey.instance_id);
  # the endpoint is the secondary physical id. 127.0.0.1 ports with nothing
  # listening: the draft builder's per-model /api/show fetch fails fast
  # (connection refused, no DNS) and degrades to absent detail evidence, so
  # drafts are built by the production builder without external network
  # dependencies.
  INSTANCE_CONFIGS = [
    {
      name: 'alpha',
      base_url: 'http://127.0.0.1:11435',
      tier: :local
    }.freeze,
    {
      name: 'beta',
      base_url: 'http://127.0.0.1:11436',
      tier: :local
    }.freeze
  ].freeze

  def initialize
    @provider_by_callable = {}
    @logger = Logger.new(File::NULL)
  end

  def provider_family = :ollama
  def instance_configs = INSTANCE_CONFIGS

  # Identity is the operator's CONFIG NAME — the production claim path
  # (DiscoveryRefresh#claim_and_activate_instance) uses name.to_s as
  # InstanceKey.instance_id, the key the router uses for instances.<name>
  # settings lookups.
  def instance_id(instance_config:)
    instance_config.fetch(:name).to_s
  end

  # Delegates to the actor's PRODUCTION physical-id derivation — the
  # secondary dedup/diagnostics field, not identity.
  def physical_id(instance_config:)
    Legion::Extensions::Llm::Ollama::Actor::DiscoveryRefresh
      .allocate.send(:derive_physical_id, instance_cfg: instance_config)
  end

  def build_callable(instance_config:)
    provider = RecordingOllamaProvider.new
    callable = Legion::Extensions::Llm::Ollama::Actor::OllamaCallable.new(
      instance_cfg: instance_config, logger: @logger, provider: provider
    )
    @provider_by_callable[callable] = provider
    callable
  end

  # Delegates to the actor's PRODUCTION draft builder (ModelDiscovery),
  # not a spec-local duplicate of the evidence construction.
  def build_offering_drafts(instance_config:, tier: :local, model_name: 'qwen3:8b', model_data: nil, **)
    actor = Legion::Extensions::Llm::Ollama::Actor::DiscoveryRefresh.allocate
    cfg = instance_config.merge(tier: tier)
    instance_id = cfg.fetch(:name).to_s
    physical_id = actor.send(:derive_physical_id, instance_cfg: cfg)
    instance_key = actor.send(:build_instance_key, instance_id: instance_id, physical_id: physical_id)
    data = model_data || {
      name: model_name,
      digest: 'sha256:specdigest',
      details: { family: 'qwen3' },
      size: 4_700_000_000
    }
    [
      actor.send(
        :build_offering_draft,
        model_name: model_name,
        model_data: data,
        instance_cfg: cfg,
        instance_key: instance_key
      )
    ]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Ollama /api/tags returned 200',
      metadata: { status: 200, base_url: instance_config[:base_url] }
    )
  end

  def inference_call_count(callable:)
    @provider_by_callable[callable]&.call_count || 0
  end

  def normalize_dispatch_error(error:)
    # The synthetic service-gone signal is the contract-test stand-in for the
    # one outcome that performs the global unavailable transition. Every real
    # error shape (Llm::*Error from the ErrorMiddleware, raw Faraday transport
    # errors) is classified by the PRODUCTION callable.
    if error.is_a?(OllamaExplicitServiceGoneSignal)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(
        kind: :instance_unavailable, reason: error.message.to_s
      )
    end

    build_callable(instance_config: instance_configs.first).normalize_dispatch_error(error: error)
  end

  # ── Real Faraday error shapes ──────────────────────────────────────────────
  # Faraday 2.x builds error.response as a Faraday::Env (a Struct, not a
  # Hash). These helpers construct errors the way Faraday itself does so the
  # conformance suite exercises the production shape, not a hand-rolled Hash.

  # Returns a Faraday::ServerError whose response is a Faraday::Env — the
  # shape a real Faraday 2.x error carries.
  def faraday_server_error(status:, body:)
    env = Faraday::Env.new
    env.status = status
    env.reason_phrase = 'Service Unavailable'
    env.response_body = body
    Faraday::ServerError.new(env)
  end

  def faraday_client_error(status:, body:)
    env = Faraday::Env.new
    env.status = status
    env.response_body = body
    Faraday::ClientError.new(env)
  end

  # Ollama emits no explicit flat instance-unavailable dispatch signal; this
  # synthetic signal exercises the shared contract example that verifies
  # instance isolation (§8 firewall — connection failures stay request-local).
  def instance_unavailable_error
    OllamaExplicitServiceGoneSignal.new(
      'Synthetic: explicit Ollama service-unavailable (contract test only)'
    )
  end

  def overloaded_error
    faraday_server_error(status: 503, body: '{"error": "Server busy"}')
  end

  def model_not_ready_error
    faraday_server_error(status: 503, body: '{"error": "model is not loaded"}')
  end
end

RSpec.describe Legion::Extensions::Llm::Ollama do
  let(:ssot_harness) { OllamaSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── Ollama-specific identity (config name + secondary physical id) ─────────

  describe 'instance identity derivation' do
    it 'uses the operator config name as the instance identity' do
      config = { name: 'server1', base_url: 'http://ollama-server-1.internal:11434' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('server1')
    end

    it 'derives the secondary physical_id as host:port from the endpoint URL' do
      config = { name: 'server1', base_url: 'http://ollama-server-1.internal:11434' }
      expect(ssot_harness.physical_id(instance_config: config)).to eq('ollama-server-1.internal:11434')
    end

    it 'derives the physical_id with a non-standard port' do
      config = { name: 'server2', base_url: 'http://ollama-server-2.internal:11435' }
      expect(ssot_harness.physical_id(instance_config: config)).to eq('ollama-server-2.internal:11435')
    end

    it 'produces distinct identities for two different config names' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'keeps two config names distinct even when they point at the same endpoint' do
      a = { name: 'apollo', base_url: 'http://127.0.0.1:11435' }
      b = { name: 'apollo-embed', base_url: 'http://127.0.0.1:11435' }
      expect(ssot_harness.instance_id(instance_config: a)).not_to eq(ssot_harness.instance_id(instance_config: b))
    end

    it 'excludes the physical_id from key equality and hashing' do
      bare = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: 'apollo'
      )
      with_physical = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: 'apollo', physical_id: '127.0.0.1:11435'
      )
      expect(bare).to eq(with_physical)
      expect(bare.hash).to eq(with_physical.hash)
    end

    it 'reproduces the same identity and physical id across multiple calls (stable)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
      phys_a = ssot_harness.physical_id(instance_config: config)
      phys_b = ssot_harness.physical_id(instance_config: config)
      expect(phys_a).to eq(phys_b)
    end

    it 'raises on a config with no endpoint (no fallback physical id)' do
      expect { ssot_harness.physical_id(instance_config: { name: 'noendpoint' }) }
        .to raise_error(ArgumentError, /no endpoint/)
    end
  end

  # ─── Two servers with same model = separate lanes ───────────────────────────

  describe 'two Ollama servers serving the same model' do
    def bring_up_instance(config, tier: :local)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, physical_id: physical_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, physical_id: physical_id,
                                                publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = Legion::Extensions::Llm::Inventory::Registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      reg = Legion::Extensions::Llm::Inventory::Registry
      first_run = bring_up_instance(config)
      first_offering_id = reg.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = reg.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      reg.reset!
      second_run = bring_up_instance(config)
      second_offering_id = reg.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = reg.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # ─── Tier change does NOT change lane/offering identity ─────────────────────

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, physical_id: physical_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, physical_id: physical_id,
                                                publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'preserves offering_id and lane_id when tier changes from local to frontier' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :local)
      reg = Legion::Extensions::Llm::Inventory::Registry

      before_offering = reg.snapshot.offerings_for(instance_key: context[:key]).first
      before_lane = reg.snapshot.lanes_for(instance_key: context[:key]).first

      frontier_drafts = ssot_harness.build_offering_drafts(
        instance_config: config, callable: context[:callable], tier: :frontier
      )
      context[:publisher].replace_instance_snapshot(
        instance_id: context[:key].instance_id,
        physical_id: context[:key].physical_id,
        publisher_token: context[:token],
        offerings: frontier_drafts,
        sequence: 1
      )

      after_offering = reg.snapshot.offerings_for(instance_key: context[:key]).first
      after_lane = reg.snapshot.lanes_for(instance_key: context[:key]).first

      expect(after_offering.offering_id).to eq(before_offering.offering_id)
      expect(after_lane.lane_id).to eq(before_lane.lane_id)
      expect(after_offering.tier).to eq(:frontier)
    end
  end

  # ─── Operation evidence controls ────────────────────────────────────────────

  describe 'operation evidence controls' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:offering) do
      ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local).first
    end

    it 'marks chat as supported' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks stream_chat as supported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks embed as unsupported for a non-embedding model' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'marks image/transcribe/translate/speak/moderate as unsupported' do
      %i[image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end

    it 'marks count_tokens as unknown' do
      expect(offering.operation_evidence[:count_tokens].status).to eq(:unknown)
    end

    it 'uses :provider_implementation source for supported/unsupported operations' do
      %i[chat stream_chat embed image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].source).to eq(:provider_implementation),
                                                          "expected #{op} source to be :provider_implementation"
      end
    end

    it 'uses :default_false source for unknown operations' do
      expect(offering.operation_evidence[:count_tokens].source).to eq(:default_false)
    end
  end

  # ─── Authoritative operation evidence for embedding models ──────────────────

  describe 'operation evidence for an embedding model' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:offering) do
      ssot_harness.build_offering_drafts(
        instance_config: config,
        model_name: 'nomic-embed-text',
        model_data: { name: 'nomic-embed-text', digest: 'sha256:embeddigest', size: 100_000_000 }
      ).first
    end

    it 'publishes chat as unsupported so a plain chat request cannot misroute' do
      expect(offering.operation_evidence[:chat].status).to eq(:unsupported)
      expect(offering.operation_evidence[:chat].source).to eq(:provider_implementation)
    end

    it 'publishes stream_chat as unsupported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:unsupported)
    end

    it 'publishes embed as supported' do
      expect(offering.operation_evidence[:embed].status).to eq(:supported)
    end

    it 'publishes the embedding capability as supported' do
      expect(offering.capability_evidence[:embedding].status).to eq(:supported)
    end
  end

  # ─── Startup gating ─────────────────────────────────────────────────────────

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama,
        instance_id: ssot_harness.instance_id(instance_config: config),
        physical_id: ssot_harness.physical_id(instance_config: config)
      )
    end
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama) }

    # Method (not let) to stay under RSpec/MultipleMemoizedHelpers.
    def callable = ssot_harness.build_callable(instance_config: config)

    def build_coordinator
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: key.instance_id, physical_id: key.physical_id, callable: callable,
                               probe_request_handle: build_coordinator)

      snapshot = Legion::Extensions::Llm::Inventory::Registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: key.instance_id, physical_id: key.physical_id, callable: callable,
                                       probe_request_handle: build_coordinator)
      probe = publisher.readiness_probe_started(instance_id: key.instance_id, physical_id: key.physical_id,
                                                publisher_token: token)
      publisher.readiness_failed(instance_id: key.instance_id, physical_id: key.physical_id, probe_token: probe,
                                 reason: 'Ollama /api/tags connection failed')

      snapshot = Legion::Extensions::Llm::Inventory::Registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: key.instance_id, physical_id: key.physical_id, callable: callable,
                                       probe_request_handle: build_coordinator)
      probe = publisher.readiness_probe_started(instance_id: key.instance_id, physical_id: key.physical_id,
                                                publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: key.instance_id, physical_id: key.physical_id, publisher_token: token,
        offerings: drafts, sequence: 0, probe_token: probe
      )

      snapshot = Legion::Extensions::Llm::Inventory::Registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # ─── Readiness probe lifecycle ──────────────────────────────────────────────

  describe 'readiness probe lifecycle' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama,
        instance_id: ssot_harness.instance_id(instance_config: config),
        physical_id: ssot_harness.physical_id(instance_config: config)
      )
    end
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama) }

    # Method (not let) to stay under RSpec/MultipleMemoizedHelpers.
    def callable = ssot_harness.build_callable(instance_config: config)

    def build_coordinator
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    def activate_instance
      token = publisher.claim_instance(instance_id: key.instance_id, physical_id: key.physical_id, callable: callable,
                                       probe_request_handle: build_coordinator)
      probe = publisher.readiness_probe_started(instance_id: key.instance_id, physical_id: key.physical_id,
                                                publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: key.instance_id, physical_id: key.physical_id, publisher_token: token,
        offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    it 'rejects a stale probe started before a newer failure' do
      token = activate_instance

      stale_probe = publisher.readiness_probe_started(instance_id: key.instance_id, physical_id: key.physical_id,
                                                      publisher_token: token)
      fresh_probe = publisher.readiness_probe_started(instance_id: key.instance_id, physical_id: key.physical_id,
                                                      publisher_token: token)

      publisher.readiness_failed(instance_id: key.instance_id, physical_id: key.physical_id, probe_token: fresh_probe,
                                 reason: 'server down')

      result = publisher.readiness_succeeded(instance_id: key.instance_id, physical_id: key.physical_id,
                                             probe_token: stale_probe)
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_probe)
    end

    it 'recovers an unavailable instance after a valid probe succeeds' do
      token = activate_instance
      reg = Legion::Extensions::Llm::Inventory::Registry

      reg.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'connection refused'
      )
      expect(reg.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)

      new_probe = publisher.readiness_probe_started(instance_id: key.instance_id, physical_id: key.physical_id,
                                                    publisher_token: token)
      publisher.readiness_succeeded(instance_id: key.instance_id, physical_id: key.physical_id,
                                    probe_token: new_probe)
      expect(reg.snapshot.instance(instance_key: key).availability.state).to eq(:available)
    end
  end

  # ─── Instance-unavailable isolation ─────────────────────────────────────────

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, physical_id: physical_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, physical_id: physical_id,
                                                publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, physical_id: physical_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])
      reg = Legion::Extensions::Llm::Inventory::Registry

      reg.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to ollama-server-1'
      )

      expect(reg.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(reg.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    it 'connection failure stays request-local and never escalates to instance_unavailable (§8 firewall)' do
      # §8: connection refusal/reset never mutates global availability.
      # Ollama's down-signal is the connection failure itself; the readiness
      # probe turns it into an availability transition — never the dispatch
      # error classification.
      conn_error = Faraday::ConnectionFailed.new(
        'Connection refused - connect(2) for 127.0.0.1:11435'
      )
      outcome = ssot_harness.normalize_dispatch_error(error: conn_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:connection_failure)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # ─── Error isolation (no global poisoning) ──────────────────────────────────

  describe 'error isolation (no global poisoning)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0]) }

    def llm_error(klass, status, body)
      env = Faraday::Env.new
      env.status = status
      env.response_body = body
      klass.new(env, status.to_s)
    end

    it 'classifies connection failure as connection_failure on the callable' do
      outcome = callable.normalize_dispatch_error(error: Faraday::ConnectionFailed.new('Connection refused'))
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      outcome = callable.normalize_dispatch_error(error: Faraday::TimeoutError.new('Net::ReadTimeout'))
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies 503 ServerError (real Faraday::Env) as overloaded on the callable' do
      outcome = callable.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'classifies 429 ClientError (real Faraday::Env) as rate_limited on the callable' do
      error = ssot_harness.faraday_client_error(status: 429, body: '{"error": "rate limit"}')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    # D17: production dispatch raises Llm::*Error (the ErrorMiddleware
    # converts HTTP statuses to Llm classes), NOT raw Faraday. The callable
    # must classify every Llm error shape — a fall-through to
    # :provider_error would misclassify 401/403/429/529 and hide the
    # connection-failure down-signal from the router.
    def classify_llm_error(error)
      callable.normalize_dispatch_error(error: error).kind
    end

    it 'classifies the Llm error shape raised by the ErrorMiddleware (D17)' do
      llm = Legion::Extensions::Llm
      expect(classify_llm_error(llm_error(llm::ServiceUnavailableError, 503, 'x'))).to eq(:provider_error)
      expect(classify_llm_error(llm_error(llm::OverloadedError, 529, 'x'))).to eq(:overloaded)
      expect(classify_llm_error(llm_error(llm::RateLimitError, 429, 'x'))).to eq(:rate_limited)
      expect(classify_llm_error(llm_error(llm::UnauthorizedError, 401, 'x'))).to eq(:authentication)
      expect(classify_llm_error(llm_error(llm::ForbiddenError, 403, 'x'))).to eq(:authorization)
      expect(classify_llm_error(llm_error(llm::BadRequestError, 400, 'x'))).to eq(:invalid_request)
      expect(classify_llm_error(llm_error(llm::ContextLengthExceededError, 400, 'too many tokens')))
        .to eq(:context_rejected)
      expect(classify_llm_error(llm::ModelNotFoundError.new('nope'))).to eq(:model_missing)
    end

    it 'classifies a 5xx model-warmup body (real Faraday::Env) as model_not_ready' do
      outcome = callable.normalize_dispatch_error(error: ssot_harness.model_not_ready_error)
      expect(outcome.kind).to eq(:model_not_ready)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      [500, 502, 503, 504].each do |status|
        env = Faraday::Env.new
        env.status = status
        env.response_body = '{"error": "server problem"}'
        error = Faraday::ServerError.new(env)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # ─── No quota domain ────────────────────────────────────────────────────────

  describe 'quota domain safety' do
    it 'does not declare quota_domains on offerings' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)

      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'Ollama offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # ─── No default model/provider ──────────────────────────────────────────────

  describe 'no default model or provider' do
    it 'accepts instance_id "default"' do
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: 'default'
      )

      expect(key.instance_id).to eq('default')
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :ollama, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'settings do not contain default_model' do
      settings = described_class.default_settings
      instance_settings = settings[:instance] || settings
      expect(instance_settings).not_to have_key(:default_model)
    end
  end

  # ─── OllamaCallable contract ────────────────────────────────────────────────

  describe Legion::Extensions::Llm::Ollama::Actor::OllamaCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    def wrapped(provider)
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider: provider
      )
    end

    it 'responds to disconnect and disconnected?' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to the fleet dispatch ops with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
      %i[chat stream_chat embed count_tokens].each do |op|
        expect(callable).to respond_to(op), "production callable must implement the fleet op ##{op}"
      end
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'delegates chat to the per-instance provider with rest passthrough' do
      provider = RecordingOllamaProvider.new
      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]
      params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.5)
      result = wrapped(provider).chat(messages, model: 'qwen3:8b', params: params)

      expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
      call = provider.calls.first
      expect(call[:operation]).to eq(:chat)
      expect(call[:messages]).to eq(messages)
      expect(call[:params]).to eq(params)
    end

    # D15 PER-OP: Ollama's render path is string-tolerant
    # (model.respond_to?(:id) ? model.id : model) for chat and embed, embed
    # places the model verbatim in the Embedding response object, and
    # count_tokens ignores it — so the fleet's RAW STRING model must pass
    # through UNWRAPPED on every op. Wrapping it in Model::Info would
    # serialize a Data object into the wire payload or the response object.
    # WorkerExecution spreads the flat wire params into the callable
    # (**params.except(:messages)) — temperature/max_tokens are
    # Canonical::Params members (05 O4), never kwargs. The boundary must fold
    # them via Canonical::Params.from_hash or the 0.8.0 funnel ArgumentErrors
    # on every fleet chat.
    it 'folds flat fleet wire params into Canonical::Params at the boundary (05 O4)' do
      provider = RecordingOllamaProvider.new
      wrapped(provider).chat([], model: 'qwen3:8b', temperature: 0.3, max_tokens: 2048)

      call = provider.calls.first
      expect(call[:params]).to be_a(Legion::Extensions::Llm::Canonical::Params)
      expect(call[:params].temperature).to eq(0.3)
      expect(call[:params].max_tokens).to eq(2048)
      expect(call).not_to have_key(:temperature)
      expect(call).not_to have_key(:max_tokens)
    end

    it 'passes the fleet raw-string model through unwrapped on every op (D15 per-op)' do
      provider = RecordingOllamaProvider.new
      wrapped(provider).chat([], model: 'qwen3:8b')
      wrapped(provider).stream_chat([], model: 'qwen3:8b')
      wrapped(provider).embed(text: 'hello', model: 'nomic-embed-text')
      wrapped(provider).count_tokens(messages: [], model: 'qwen3:8b')

      provider.calls.each do |call|
        expect(call[:model]).to be_a(String), "op #{call[:operation]} must pass the raw string through"
      end
      expect(provider.calls.map { |c| c[:operation] }).to eq(%i[chat stream_chat embed count_tokens])
      expect(provider.calls[2]).to include(text: 'hello', model: 'nomic-embed-text')
    end

    it 'passes a Model::Info model through unchanged (D15 pass-through)' do
      provider = RecordingOllamaProvider.new
      info = Legion::Extensions::Llm::Model::Info.new(id: 'qwen3:8b', provider: :ollama)

      wrapped(provider).chat([], model: info)

      expect(provider.calls.first[:model]).to equal(info)
    end

    # D15 PER-OP against the REAL render path: the production Provider's
    # render methods must accept the dispatch's raw string model (no
    # NoMethodError on model.id anywhere in the chat/stream_chat/embed
    # render paths). Messages are the Canonical::Message objects the
    # dispatch layer hands the provider; the model is the raw string under test.
    it 'drives the real render path with a raw string model (D15 per-op)' do
      provider = Legion::Extensions::Llm::Ollama::Provider.new(base_url: 'http://127.0.0.1:11437')
      message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')
      chat_payload = provider.send(
        :render_payload, [message],
        tools: [], params: nil, model: 'qwen3:8b',
        stream: false, schema: nil, thinking: nil, tool_prefs: nil
      )
      expect(chat_payload[:model]).to eq('qwen3:8b')

      embed_payload = provider.send(:render_embedding_payload, 'hello', model: 'nomic-embed-text', dimensions: nil)
      expect(embed_payload[:model]).to eq('nomic-embed-text')
    ensure
      provider&.disconnect
    end

    it 'closes the per-instance provider on disconnect' do
      provider = RecordingOllamaProvider.new
      wrapped(provider).disconnect

      expect(provider.disconnected).to be(true)
    end

    it 'lets dispatch errors propagate unrescued (errors escape chat for classification)' do
      raising = Class.new do
        # Part of the production provider interface the callable checks
        # before delegating (0.8.0 base); delegate to the real code.
        def enforce_canonical_messages!(messages)
          Legion::Extensions::Llm::Ollama::Provider.new({}).enforce_canonical_messages!(messages)
        end

        def chat(_messages, **_rest)
          raise Faraday::ConnectionFailed, 'connection refused'
        end
      end.new
      expect { wrapped(raising).chat([], model: 'qwen3:8b') }
        .to raise_error(Faraday::ConnectionFailed)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end
  end

  # ─── Dispatch boundary regression guards (2026-08-19 incident) ─────────────
  # SSOT v3 local dispatch passed executor Hash messages straight to the
  # provider callable, bypassing the canonical contract; lenient
  # provider-side re-canonicalization masked the bypass (25/25 failed openai
  # dispatches). As of lex-llm 0.7.7 the fleet worker rehydrates wire
  # messages to Canonical::Message, and this provider's callable + render
  # seam reject plain-Hash input loudly — no hash tolerance, no
  # re-canonicalization bridge. The Ollama wire format is unchanged.
  describe 'dispatch boundary regression (2026-08-19)' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:provider) { Legion::Extensions::Llm::Ollama::Provider.new(config) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }

    # The exact shape the dispatch layer delivers: Canonical::Message
    # objects, with the prompt-cache breakpoint riding as a first-class
    # canonical member (lex-llm 0.7.7).
    def canonical_request
      [
        Legion::Extensions::Llm::Canonical::Message.build(
          role: :system, content: 'Be terse.', cache_control: { type: 'ephemeral' }
        ),
        Legion::Extensions::Llm::Canonical::Message.build(
          role: :user, content: 'What is the capital of France?'
        )
      ]
    end

    # The 2026-08-19 defect class: plain-Hash messages from the executor,
    # silently re-canonicalized provider-side before the fix.
    def hash_request
      [
        { role: 'system', content: 'Be terse.', cache_control: { type: 'ephemeral' } },
        { role: 'user', content: 'What is the capital of France?' }
      ]
    end

    def render(messages)
      provider.send(
        :render_payload, messages,
        tools: [], params: nil, model: 'qwen3:8b',
        stream: false, schema: nil, thinking: nil, tool_prefs: nil
      )
    end

    it 'renders canonical messages through the production render seam without leaking cache_control' do
      # render_payload is the production render seam (Provider#complete ->
      # render_payload); calling it directly keeps the example HTTP-free.
      # Canonical input with a :cache_control member must render to the
      # Ollama wire without the transport-only key.
      wire = render(canonical_request)

      expect(wire[:messages]).to eq(
        [
          { role: 'system', content: 'Be terse.' },
          { role: 'user', content: 'What is the capital of France?' }
        ]
      )
      wire[:messages].each { |m| expect(m).not_to have_key(:cache_control) }
    end

    it 'rejects plain Hash messages at the dispatch boundary instead of re-canonicalizing them' do
      # The 2026-08-19 defect class: hash messages silently re-canonicalized
      # provider-side masked the bypass. In 0.8.0 the boundary rejects loudly
      # at both the fleet callable (shared-helper call) and the base funnel
      # (central enforcement, 08 F2) — no render-seam re-implementation.
      expect { callable.chat(hash_request, model: 'qwen3:8b') }
        .to raise_error(ArgumentError, /Canonical::Message/)
      expect { provider.chat(hash_request, model: 'qwen3:8b') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'runs the base shared enforce helper (no per-provider re-implementation)' do
      expect(
        Legion::Extensions::Llm::Ollama::Provider.instance_method(:enforce_canonical_messages!).owner
      ).to eq(Legion::Extensions::Llm::Provider)
    end
  end

  # ─── 0.8.0 boundary kit groups (09 B1/B2) — the real callable boundary ────
  # B1 (central enforcement) and B2 (canonical outputs, asserted by type) run
  # against the PRODUCTION OllamaCallable wrapping a real Ollama::Provider —
  # the offline fake replaces only the Provider's HTTP connection, so the
  # production render_payload / parse_completion_response / stream_response
  # boundaries all execute (the documented matrix blind spot, closed at the
  # kit level: provider-side examples must traverse render/parse).
  describe '0.8.0 boundary conformance (kit B1/B2)' do
    def build_real_callable
      stream_lines = [
        Legion::JSON.dump('message' => { 'role' => 'assistant', 'content' => 'streamed' }, 'model' => 'qwen3:8b'),
        Legion::JSON.dump(
          'message' => { 'role' => 'assistant', 'content' => '' }, 'model' => 'qwen3:8b',
          'done' => true, 'done_reason' => 'stop', 'prompt_eval_count' => 5, 'eval_count' => 3
        )
      ].map { |line| "#{line}\n" }
      connection = Object.new
      connection.define_singleton_method(:post) do |_path, payload, &request_block|
        if payload[:stream]
          req = Struct.new(:headers, :options).new({}, Struct.new(:on_data).new(nil))
          request_block&.call(req)
          env = Faraday::Env.new
          env.status = 200
          stream_lines.each { |line| req.options.on_data.call(line, line.bytesize, env) }
          Struct.new(:body).new('')
        else
          request_block&.call(Struct.new(:headers).new({}))
          Struct.new(:body).new(
            {
              'model' => 'qwen3:8b',
              'message' => { 'role' => 'assistant', 'content' => 'ok' },
              'done' => true,
              'done_reason' => 'stop',
              'prompt_eval_count' => 2,
              'eval_count' => 1
            }
          )
        end
      end
      connection.define_singleton_method(:close) { true }
      provider = Legion::Extensions::Llm::Ollama::Provider.new(base_url: 'http://127.0.0.1:11435')
      provider.instance_variable_set(:@connection, connection)
      Legion::Extensions::Llm::Ollama::Actor::OllamaCallable.new(
        instance_cfg: { base_url: 'http://127.0.0.1:11435' },
        logger: Logger.new(File::NULL),
        provider: provider
      )
    end

    let(:callable) { build_real_callable }

    it_behaves_like 'B1 — central canonical enforcement (08 F2)'
    it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'
  end

  # ─── ReadinessResult contract ───────────────────────────────────────────────

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end

  # ─── No Legion::LLM reverse dependency ──────────────────────────────────────

  describe 'dependency isolation' do
    it 'does not require Legion::LLM in the discovery actor' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/ollama/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'OllamaCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end
end
