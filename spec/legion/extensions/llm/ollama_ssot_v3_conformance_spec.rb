# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
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

# Stub the actor runtime so discovery_refresh.rb loads the OllamaCallable class.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        class Every
          def self.every_seconds = 300
        end
      end
    end

    module Helpers
      module Lex; end unless const_defined?(:Lex, false)
    end
  end
end

# Force re-evaluation since spec_helper already loaded the file (which returned
# early because Actors::Every wasn't defined at that point).
actor_path = File.expand_path('../../../../lib/legion/extensions/llm/ollama/actors/discovery_refresh.rb', __dir__)
load actor_path

# rubocop:disable RSpec/MultipleMemoizedHelpers

# Test-local callable extending OllamaCallable with dispatch operations
# and inference call tracking for conformance assertions.
class TrackingOllamaCallable < Legion::Extensions::Llm::Ollama::Actor::OllamaCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(messages:, model:, **) # rubocop:disable Lint/UnusedMethodArgument -- callable contract
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(messages:, model:, **) # rubocop:disable Lint/UnusedMethodArgument -- callable contract
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(text:, model:, **) # rubocop:disable Lint/UnusedMethodArgument -- callable contract
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model }
  end

  def count_tokens(messages:, model:, **) # rubocop:disable Lint/UnusedMethodArgument -- callable contract
    @call_count += 1
    { token_count: 42, model: model }
  end
end

# Harness class for Ollama SSOT v3 conformance testing.
class OllamaSsotHarness
  INSTANCE_CONFIGS = [
    {
      base_url: 'http://ollama-server-1.internal:11434',
      tier: :local
    }.freeze,
    {
      base_url: 'http://ollama-server-2.internal:11435',
      tier: :local
    }.freeze
  ].freeze

  def provider_family = :ollama
  def instance_configs = INSTANCE_CONFIGS

  def instance_id(instance_config:)
    base_url = instance_config[:base_url] || instance_config[:endpoint] || 'http://127.0.0.1:11434'
    uri = URI.parse(base_url.to_s)
    host = uri.host || '127.0.0.1'
    port = uri.port || 11_434
    "#{host}:#{port}"
  rescue URI::InvalidURIError
    'unknown:0'
  end

  def build_callable(instance_config:)
    TrackingOllamaCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :local, **)
    now = Time.now.freeze
    model_id = 'qwen3:8b'
    [build_single_offering(model_id: model_id, tier: tier, now: now)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Ollama /api/tags returned 200',
      metadata: { status: 200, base_url: instance_config[:base_url] }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_ollama_escalation(outcome: outcome, error: error)
  end

  def instance_unavailable_error
    # Ollama does NOT produce a distinct instance-unavailable signal.
    # Connection failure is the closest proxy for a truly dead server,
    # and the harness escalates it to instance_unavailable.
    Faraday::ConnectionFailed.new('Connection refused - connect(2) for ollama-server-1.internal:11434')
  end

  def overloaded_error
    response = { status: 503, headers: {}, body: '{"error": "Server busy"}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def model_not_ready_error
    response = { status: 503, headers: {}, body: '{"error": "model is not loaded"}' }
    Faraday::ServerError.new('the server responded with status 503 - model is not loaded', response)
  end

  private

  def apply_ollama_escalation(outcome:, error:)
    # Ollama connection failure = the server process is unreachable.
    # This is the authoritative signal for instance_unavailable.
    if outcome.kind == :connection_failure && error.is_a?(Faraday::ConnectionFailed)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(
        kind: :instance_unavailable, reason: outcome.reason
      )
    end

    outcome
  end

  def build_single_offering(model_id:, tier:, now:)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, embed_supported: false),
      capability_evidence: build_capability_evidence,
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: 128_000, source: :provider_catalog
      ),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: {}, metadata: { raw_model: model_id }, publication_source: :provider_catalog
    )
  end

  def build_operation_evidence(now:, embed_supported:)
    embed_status = embed_supported ? :supported : :unsupported
    {
      chat: op_evidence(:chat, :supported, now),
      stream_chat: op_evidence(:stream_chat, :supported, now),
      embed: op_evidence(:embed, embed_status, now),
      image: op_evidence(:image, :unsupported, now),
      transcribe: op_evidence(:transcribe, :unsupported, now),
      translate: op_evidence(:translate, :unsupported, now),
      speak: op_evidence(:speak, :unsupported, now),
      moderate: op_evidence(:moderate, :unsupported, now),
      count_tokens: op_evidence(:count_tokens, :unknown, now)
    }
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_implementation
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      )
    }
  end
end

RSpec.describe Legion::Extensions::Llm::Ollama do
  let(:ssot_harness) { OllamaSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # -- Ollama-specific identity derivation ------------------------------------

  describe 'instance identity derivation' do
    it 'derives instance_id as host:port from endpoint URL' do
      config = { base_url: 'http://ollama-server-1.internal:11434' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('ollama-server-1.internal:11434')
    end

    it 'derives instance_id with non-standard port' do
      config = { base_url: 'http://ollama-server-2.internal:11435' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('ollama-server-2.internal:11435')
    end

    it 'produces distinct instance IDs for two different endpoints' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'defaults to 127.0.0.1:11434 when no endpoint configured' do
      config = {}
      expect(ssot_harness.instance_id(instance_config: config)).to eq('127.0.0.1:11434')
    end
  end

  # -- Two servers with same model = separate lanes ---------------------------

  describe 'two Ollama servers serving the same model' do
    def bring_up_instance(config, tier: :local)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
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
      first_run = bring_up_instance(config)
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # -- Tier change does NOT change lane/offering identity ---------------------

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'preserves offering_id and lane_id when tier changes from local to frontier' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :local)

      before_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      before_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      frontier_drafts = ssot_harness.build_offering_drafts(
        instance_config: config, callable: context[:callable], tier: :frontier
      )
      context[:publisher].replace_instance_snapshot(
        instance_id: ssot_harness.instance_id(instance_config: config),
        publisher_token: context[:token],
        offerings: frontier_drafts,
        sequence: 1
      )

      after_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      after_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      expect(after_offering.offering_id).to eq(before_offering.offering_id)
      expect(after_lane.lane_id).to eq(before_lane.lane_id)
      expect(after_offering.tier).to eq(:frontier)
    end
  end

  # -- Operation evidence controls -------------------------------------------

  describe 'operation evidence controls' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local) }
    let(:offering) { drafts.first }

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

  # -- Startup gating --------------------------------------------------------

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:instance_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id
      )
    end
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      publisher.readiness_failed(instance_id: instance_id, probe_token: probe,
                                 reason: 'Ollama /api/tags connection failed')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # -- Readiness probe lifecycle ---------------------------------------------

  describe 'readiness probe lifecycle' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:instance_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id
      )
    end
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    def activate_instance
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    it 'rejects a stale probe started before a newer failure' do
      token = activate_instance

      stale_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      fresh_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)

      publisher.readiness_failed(instance_id: instance_id, probe_token: fresh_probe, reason: 'server down')

      result = publisher.readiness_succeeded(instance_id: instance_id, probe_token: stale_probe)
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_probe)
    end

    it 'recovers an unavailable instance after a valid probe succeeds' do
      token = activate_instance

      registry.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'connection refused'
      )
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)

      new_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      publisher.readiness_succeeded(instance_id: instance_id, probe_token: new_probe)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
    end
  end

  # -- Instance-unavailable isolation ----------------------------------------

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :ollama, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to ollama-server-1'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    it 'normalizes connection failure as instance_unavailable through the harness' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # -- Error isolation -------------------------------------------------------

  describe 'error isolation (no global poisoning)' do
    it 'classifies connection failure as connection_failure on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies 503 ServerError as overloaded on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 503, headers: {}, body: '' }
      error = Faraday::ServerError.new('503', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'classifies 429 ClientError as rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # -- No quota domain -------------------------------------------------------

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

  # -- No default model/provider ---------------------------------------------

  describe 'no default model or provider' do
    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :ollama, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
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

  # -- OllamaCallable contract -----------------------------------------------

  describe Legion::Extensions::Llm::Ollama::Actor::OllamaCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end
  end

  # -- ReadinessResult contract ----------------------------------------------

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

  # -- No Legion::LLM reverse dependency ------------------------------------

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

# rubocop:enable RSpec/MultipleMemoizedHelpers
