# frozen_string_literal: true

require 'concurrent'
require 'json'
require 'time'
require 'uri'
require 'faraday'

begin
  require 'legion/extensions/actors/every'
rescue LoadError
  nil
end

unless defined?(Legion::Extensions::Actors::Every)
  raise LoadError, 'LegionIO actor runtime is required for Ollama discovery'
end

require 'legion/extensions/llm/ollama/provider'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/weight_reconciler'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

module Legion
  module Extensions
    module Llm
      module Ollama
        module Actor
          # ── Operation/capability evidence helpers ───────────────────────────
          module EvidenceBuilder
            private

            # Authoritative operation evidence (matches how bedrock excludes
            # embedding models): an EMBEDDING model publishes chat and
            # stream_chat as :unsupported so a plain chat request cannot
            # misroute to an embedding instance, and a chat model publishes
            # embed as :unsupported.
            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              chat_status = embed_supported ? :unsupported : :supported
              embed_status = embed_supported ? :supported : :unsupported

              {
                chat: op_evidence(operation: :chat, status: chat_status, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: chat_status, observed_at: now),
                embed: op_evidence(operation: :embed, status: embed_status, observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation,
                status: status,
                source: source,
                observed_at: observed_at
              )
            end

            def build_capability_evidence(model_name:, model_data:, detail:)
              evidence = {
                completion: cap_evidence(capability: :completion, status: :supported,
                                         source: :provider_implementation),
                streaming: cap_evidence(capability: :streaming, status: :supported,
                                        source: :provider_implementation)
              }

              evidence[:tools] = resolve_tools_evidence(detail: detail)
              evidence[:thinking] = resolve_thinking_evidence(detail: detail)
              evidence[:vision] = resolve_vision_evidence(model_name: model_name, model_data: model_data)

              if embedding_model?(model_name: model_name, model_data: model_data)
                evidence[:embedding] = cap_evidence(capability: :embedding, status: :supported,
                                                    source: :provider_implementation)
              end

              evidence
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability,
                status: status,
                source: source,
                observed_at: Time.now.freeze
              )
            end

            def resolve_tools_evidence(detail:)
              return cap_evidence(capability: :tools, status: :unknown, source: :default_false) unless detail

              caps = detail[:capabilities]
              if caps.is_a?(Array) && (caps.include?('tools') || caps.include?(:tools))
                cap_evidence(capability: :tools, status: :supported, source: :provider_catalog)
              else
                cap_evidence(capability: :tools, status: :unknown, source: :default_false)
              end
            end

            def resolve_thinking_evidence(detail:)
              return cap_evidence(capability: :thinking, status: :unknown, source: :default_false) unless detail

              caps = detail[:capabilities]
              if caps.is_a?(Array) && (caps.include?('thinking') || caps.include?(:thinking))
                cap_evidence(capability: :thinking, status: :supported, source: :provider_catalog)
              else
                cap_evidence(capability: :thinking, status: :unknown, source: :default_false)
              end
            end

            def resolve_vision_evidence(model_data:, **)
              caps = model_data[:capabilities] || model_data['capabilities']
              if caps.is_a?(Array) && (caps.include?('vision') || caps.include?(:vision))
                cap_evidence(capability: :vision, status: :supported, source: :provider_catalog)
              else
                cap_evidence(capability: :vision, status: :unknown, source: :default_false)
              end
            end

            def embedding_model?(model_name:, model_data:)
              caps = model_data[:capabilities] || model_data['capabilities']
              return true if caps.is_a?(Array) && (caps.include?('embedding') || caps.include?(:embedding))

              model_name.to_s.match?(/embed/i)
            end
          end

          # ── Value evidence helpers ────────────────────────────────────────────
          module ValueEvidenceBuilder
            private

            def build_context_evidence(detail:)
              return absent_value_evidence unless detail

              ctx = detail[:context_window]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(embed_supported:, detail:)
              return absent_value_evidence unless embed_supported && detail

              dims = detail[:embedding_dimensions]
              if dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: dims.uniq.sort, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_model_revision_evidence(model_data:)
              digest = model_data[:digest] || model_data['digest']
              if digest.is_a?(String) && !digest.strip.empty?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: digest.strip, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :unknown, source: :absent
              )
            end

            def extract_context_window_from_detail(body:)
              model_info = body[:model_info] || body['model_info']
              if model_info.is_a?(Hash)
                ctx_val = model_info[:num_ctx] || model_info['num_ctx'] ||
                          model_info.find { |k, _| k.to_s.end_with?('.context_length') }&.last
                return ctx_val.to_i if ctx_val&.to_i&.positive?
              end

              params = body[:parameters] || body['parameters']
              if params.is_a?(String)
                match = params.match(/num_ctx\s+(\d+)/)
                return match[1].to_i if match
              end

              nil
            end

            def build_offering_metadata(model_name:, model_data:)
              meta = { raw_model: model_name }
              family = model_data.dig(:details, :family) || model_data.dig('details', 'family')
              meta[:family] = family.to_s if family
              size = model_data[:size] || model_data['size']
              meta[:size_bytes] = size if size.is_a?(Integer)
              meta
            end
          end

          # ── Model discovery helpers ──────────────────────────────────────────
          module ModelDiscovery
            private

            # Only transport and body-parse failures yield "no offerings".
            # Programming errors (NameError/NoMethodError/ArgumentError) must
            # propagate to the caller's loud log path — rescuing them here
            # would publish an activated instance with ZERO offerings
            # (invisible to the router) while looking healthy.
            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)
              models.filter_map do |model_data|
                model_name = (model_data[:name] || model_data['name']).to_s
                next if model_name.empty?

                build_offering_draft(
                  model_name: model_name, model_data: model_data,
                  instance_cfg: instance_cfg, instance_key: instance_key
                )
              end
            rescue Faraday::Error, Legion::JSON::ParseError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              base_url = resolve_api_base(instance_cfg: instance_cfg)
              conn = build_api_connection(base_url: base_url)
              response = conn.get('/api/tags')
              body = Legion::JSON.load(response.body)
              body.fetch(:models, [])
            end

            def build_offering_draft(model_name:, model_data:, instance_cfg:, instance_key:)
              tier = instance_cfg[:tier] || :local
              detail = fetch_model_detail_safe(model_name: model_name, instance_cfg: instance_cfg)
              embed_supported = embedding_model?(model_name: model_name, model_data: model_data)
              weight_inputs = Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
                settings: Legion::Settings,
                instance_key: instance_key,
                provider_native_key: model_name,
                model: model_name,
                tier: tier
              )

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_name,
                model: model_name,
                tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_supported),
                capability_evidence: build_capability_evidence(
                  model_name: model_name, model_data: model_data, detail: detail
                ),
                context_evidence: build_context_evidence(detail: detail),
                max_output_evidence: absent_value_evidence,
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(
                  embed_supported: embed_supported, detail: detail
                ),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: absent_value_evidence,
                quota_domains: {},
                metadata: build_offering_metadata(model_name: model_name, model_data: model_data)
                          .merge(instance_id: instance_key.instance_id),
                publication_source: :provider_catalog,
                weight_inputs: weight_inputs,
                base_weight: Legion::Extensions::Llm::Inventory::WeightSchema.base_weight(weight_inputs)
              )
            end

            # Per-model detail is optional enrichment; a transport or
            # body-parse failure degrades that model's evidence to :unknown
            # without failing the discovery. Programming errors propagate.
            def fetch_model_detail_safe(model_name:, instance_cfg:)
              base_url = resolve_api_base(instance_cfg: instance_cfg)
              conn = build_api_connection(base_url: base_url)
              response = conn.post('/api/show', Legion::JSON.dump({ model: model_name }))
              body = Legion::JSON.load(response.body)
              parse_model_detail(body: body)
            rescue Faraday::Error, Legion::JSON::ParseError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.fetch_model_detail',
                                  model: model_name)
              nil
            end

            def parse_model_detail(body:)
              ctx = extract_context_window_from_detail(body: body)
              caps = body[:capabilities] || body['capabilities']
              dims = body[:embedding_dimensions] || body['embedding_dimensions']
              {
                context_window: ctx,
                capabilities: caps.is_a?(Array) ? caps : nil,
                embedding_dimensions: dims.is_a?(Array) ? dims : nil
              }.compact
            end
          end

          # ── Instance configuration helpers ───────────────────────────────────
          module ConfigResolver
            private

            # Single source of truth for which instances are claimable lives in
            # the entry module (Ollama.configured_instances): only
            # operator-configured instances, the synthetic instances.default
            # skipped while unmodified, no port-scanning, no fabricated
            # instances, no endpoint fallback. The actor and the fleet
            # responder must never disagree about the instance set.
            def configured_instances
              Legion::Extensions::Llm::Ollama.configured_instances
            end
          end

          # ── HTTP connection + identity helpers ───────────────────────────────
          module HttpClient
            private

            # No endpoint fallback: claimable_instance_config guarantees a
            # base_url before an instance is ever claimed, so a missing
            # endpoint here is a programming error, not a default.
            def resolve_api_base(instance_cfg:)
              (instance_cfg[:base_url] || instance_cfg[:endpoint]).to_s
            end

            def build_readiness_connection(base_url:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 5
                f.options.open_timeout = 3
                f.adapter Faraday.default_adapter
              end
            end

            def build_api_connection(base_url:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                f.headers['Content-Type'] = 'application/json'
                f.adapter Faraday.default_adapter
              end
            end

            # Secondary PHYSICAL id (dedup/diagnostics), not identity: the
            # exact host:port the operator configured — the thing that can
            # independently become unavailable. Identity is the config NAME
            # (InstanceKey.instance_id), so two config names pointing at the
            # same endpoint stay distinct instances. No host or port
            # fallback (a fallback physical id would mask a missing endpoint).
            def derive_physical_id(instance_cfg:)
              base_url = instance_cfg[:base_url] || instance_cfg[:endpoint]
              unless base_url.is_a?(String) && !base_url.strip.empty?
                raise ArgumentError, "ollama instance has no endpoint: #{base_url.inspect}"
              end

              extract_host_port(url: base_url)
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host
              raise ArgumentError, "ollama instance endpoint has no host: #{url.inspect}" if host.nil? || host.empty?

              "#{host}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.extract_host_port', url: url.to_s)
              raise
            end
          end

          # ── Readiness probe helpers ──────────────────────────────────────────
          module ProbeRunner
            private

            def run_cadence_probe(state:)
              instance_id = state[:instance_id]
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, physical_id: state[:physical_id],
                publisher_token: state[:publisher_token]
              )
              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              report_probe_result(instance_id: instance_id, physical_id: state[:physical_id],
                                  probe_token: probe_token, readiness: readiness)
              sync_display_health(state: state)
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn, operation: 'ollama.actor.cadence_probe.finish_probe',
                                             instance_id: state[:instance_id])
              end
              handle_exception(e, level: :warn, operation: 'ollama.actor.cadence_probe',
                                  instance_id: state[:instance_id])
            end

            # name is the CONFIG NAME — the @instance_states key. The
            # publisher calls use the state's instance_id + physical_id pair.
            def handle_reactive_probe(name:, request:)
              state = @state_mutex.synchronize { @instance_states[name] }
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: state[:instance_id], physical_id: state[:physical_id],
                publisher_token: state[:publisher_token]
              )
              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              report_probe_result(instance_id: state[:instance_id], physical_id: state[:physical_id],
                                  probe_token: probe_token, readiness: readiness)
              sync_display_health(state: state)
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn, operation: 'ollama.actor.reactive_probe.finish_probe',
                                             instance_id: state[:instance_id])
              end
              handle_exception(e, level: :warn, operation: 'ollama.actor.reactive_probe',
                                  instance_id: state[:instance_id])
            end

            def report_probe_result(instance_id:, physical_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(
                  instance_id: instance_id, physical_id: physical_id, probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id, physical_id: physical_id, probe_token: probe_token,
                  reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(name:)
              proc do |request:|
                handle_reactive_probe(name: name, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.probe_enqueue',
                                    instance_name: name.to_s)
                false
              end
            end
          end

          # ── Health check helpers ─────────────────────────────────────────────
          module HealthChecker
            private

            # Safe readiness: GET /api/tags is a model listing — non-inference,
            # non-billable. Never a chat/embed/generation call.
            def check_readiness(instance_cfg:)
              base_url = resolve_api_base(instance_cfg: instance_cfg)
              conn = build_readiness_connection(base_url: base_url)
              response = conn.get('/api/tags')
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.check_readiness.connection',
                                  base_url: base_url)
              readiness_failure(reason: "Ollama /api/tags connection failed: #{e.message}", error: e)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.check_readiness',
                                  base_url: base_url)
              readiness_failure(reason: "Ollama /api/tags error: #{e.message}", error: e)
            end

            # Status detection handles every real response shape:
            # Faraday::Response (the normal conn.get result) and Faraday::Env /
            # plain Hash (middleware-wrapped or hand-built).
            def build_readiness_from_response(response:, base_url:)
              status = readiness_status(response)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: status == 200,
                reason: "Ollama /api/tags returned #{status}",
                metadata: { status: status, base_url: base_url }
              )
            end

            def readiness_status(response)
              return response.status if response.respond_to?(:status) && response.status
              return response[:status] if response.respond_to?(:[])

              nil
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false,
                reason: reason,
                metadata: { error_class: error.class.name }
              )
            end
          end

          # ── Offering change comparison helpers ───────────────────────────────
          module OfferingComparison
            SCALAR_EVIDENCE_FIELDS = %i[
              context_evidence max_output_evidence embedding_dimensions_evidence
              model_revision_evidence tokenizer_evidence
            ].freeze

            private

            # Every draft embeds fresh evidence observed_at telemetry. Compare
            # the complete stable draft contract as a multiset so catalog order
            # is irrelevant while duplicate counts remain significant.
            def offerings_changed?(previous:, current:)
              offering_multiset(current) != offering_multiset(previous)
            end

            def offering_multiset(offerings)
              offerings.map { |draft| stable_offering_state(draft) }.tally
            end

            def stable_offering_state(draft)
              state = draft.to_h
              state[:operation_evidence] = stable_evidence_map(draft.operation_evidence)
              state[:capability_evidence] = stable_evidence_map(draft.capability_evidence)
              SCALAR_EVIDENCE_FIELDS.each do |field|
                state[field] = stable_evidence(draft.public_send(field))
              end
              state
            end

            def stable_evidence_map(evidence)
              evidence.transform_values { |entry| stable_evidence(entry) }
            end

            def stable_evidence(evidence)
              evidence.to_h.except(:observed_at)
            end
          end

          # ── Settings display health helpers (D14) ────────────────────────────
          module DisplayHealth
            private

            # Display-only health/capabilities for the status API, written after
            # each registry commit. The key is the CONFIG name
            # (settings[:instances] key), never the derived instance_id.
            # Routing authority stays the in-memory AvailabilityFact; this hash
            # is never read by the router.
            def sync_display_health(state:)
              entry = instance_settings_entry(name: state[:name])
              return unless entry.is_a?(Hash)

              entry.merge!(display_health_entry(state: state))
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.sync_display_health',
                                  instance_id: state[:instance_id])
            end

            def display_health_entry(state:)
              record = publisher.snapshot.instance(instance_key: state[:instance_key])
              status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
              {
                health: display_health(availability: record&.availability, status: status),
                capabilities: instance_capabilities(state[:offerings])
              }
            end

            def clear_display_health(name:)
              entry = instance_settings_entry(name: name)
              return unless entry.is_a?(Hash)

              entry.delete(:health)
              entry.delete(:capabilities)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.clear_display_health',
                                  instance_name: name.to_s)
            end

            def instance_settings_entry(name:)
              instances = settings[:instances]
              return nil unless instances.is_a?(Hash)

              instances[name] || instances[name.to_s]
            end

            def display_health(availability:, status:)
              available = availability&.state == :available
              {
                circuit_state: available ? :closed : :open,
                denied: false,
                available: available,
                adjustment: available ? 0 : -50,
                reason: health_reason(availability: availability, status: status),
                observed_at: health_observed_at(availability: availability, status: status),
                last_probe_outcome: status.last_probe_outcome,
                source: health_source(availability: availability)
              }
            end

            def health_reason(availability:, status:)
              availability&.reason || status.last_error
            end

            # Display timestamps are ISO8601 UTC strings (getutc) so the
            # settings tree stays serializable.
            def health_observed_at(availability:, status:)
              time = availability&.observed_at || status.last_probe_completed_at || Time.now
              time.getutc.iso8601(3)
            end

            def health_source(availability:)
              availability&.source || :initial_readiness
            end

            def instance_capabilities(offerings)
              offerings.flat_map do |draft|
                draft.capability_evidence.filter_map do |capability, evidence|
                  evidence.supported? ? capability : nil
                end
              end.uniq.sort
            end
          end

          # ── Instance component helpers ───────────────────────────────────────
          module InstanceComponents
            private

            def build_instance_key(instance_id:, physical_id:)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :ollama, instance_id: instance_id, physical_id: physical_id
              )
            end

            def build_instance_components(name:, instance_id:, physical_id:, instance_cfg:, instance_key:)
              callable = OllamaCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key, enqueue: build_probe_enqueue(name: name)
              )
              publisher_token = publisher.claim_instance(
                instance_id: instance_id, physical_id: physical_id, callable: callable,
                probe_request_handle: probe_coordinator
              )
              { callable: callable, probe_coordinator: probe_coordinator, publisher_token: publisher_token }
            end

            # Identity is the operator's CONFIG NAME (InstanceKey.instance_id)
            # — the key the router uses for instances.<name> settings lookups.
            # The derived host:port rides along as the SECONDARY physical_id
            # (dedup/diagnostics only), so two config names pointing at the
            # same endpoint stay distinct instances and name-keyed tuning and
            # enable_* overrides stay effective.
            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = name.to_s
              physical_id = derive_physical_id(instance_cfg: instance_cfg)
              instance_key = build_instance_key(instance_id: instance_id, physical_id: physical_id)
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              components = build_instance_components(
                name: name.to_sym, instance_id: instance_id, physical_id: physical_id,
                instance_cfg: instance_cfg, instance_key: instance_key
              )
              state = {
                name: name.to_sym,
                instance_id: instance_id,
                physical_id: physical_id,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: components[:callable],
                probe_coordinator: components[:probe_coordinator],
                publisher_token: components[:publisher_token],
                sequence: 0,
                offerings: offerings
              }
              Legion::Extensions::Llm::Inventory::WeightReconciler.track_initializing!(
                states: @instance_states,
                state_key: name.to_sym,
                state: state,
                mutex: @state_mutex
              )
              settled = settle_initial_readiness(state: state)
              sync_display_health(state: state) if settled
            end

            def drop_instance(name:, state:)
              removed = @state_mutex.synchronize do
                next false unless @instance_states[name].equal?(state)

                publisher.remove_instance(
                  instance_id: state[:instance_id], physical_id: state[:physical_id],
                  publisher_token: state[:publisher_token]
                )
                @instance_states.delete(name)
                true
              end
              return unless removed

              state[:callable]&.disconnect
              clear_display_health(name: state[:name])
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.remove_instance',
                                  instance_id: state[:instance_id])
            end
          end

          # Atomic adapters and dormant observation shared by the existing
          # discovery cadence. Sequence and cache mutation remain owned by
          # lex-llm's WeightReconciler.
          module WeightPublication
            private

            def replace_offerings_if_changed(state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              changed = Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                settings: Legion::Settings,
                instance_id: state[:instance_id],
                state: state,
                discovered_offerings: new_offerings,
                mutex: @state_mutex,
                equivalent: lambda do |previous, current|
                  !offerings_changed?(previous: previous, current: current)
                end,
                replace: method(:replace_weight_snapshot)
              )
              published = @state_mutex.synchronize { state[:published] }
              sync_display_health(state: state) if changed && published
              changed
            end

            def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
              publisher.replace_instance_snapshot(
                instance_id: instance_id,
                physical_id: state[:physical_id],
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence
              )
            end

            def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
              publisher.activate_instance_snapshot(
                instance_id: instance_id,
                physical_id: state.fetch(:physical_id),
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                probe_token: probe_token
              )
            end

            def observe_dormant_weights
              Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
                settings: Legion::Settings,
                provider_family: :ollama,
                states: @instance_states,
                mutex: @state_mutex,
                tracker: @dormant_weight_tracker,
                dormant_logger: lambda do |key|
                  log.info do
                    "[llm][ollama] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                  end
                end
              )
            end

            def remove_all_instances
              return unless @instance_states

              states = @state_mutex.synchronize { @instance_states.each_pair.to_a }
              states.each do |name, state|
                drop_instance(name: name, state: state)
              end
              @state_mutex.synchronize do
                @instance_states.clear
                @dormant_weight_tracker.clear!
              end
            end
          end

          # Per-instance SSOT lifecycle: reconcile configured instances each
          # tick, run the readiness state machine (initial probe, recovery
          # while :initializing, cadence probes, snapshot replacement), and
          # retire instances on shutdown.
          module InstanceLifecycle
            private

            def initial_discovery
              @instance_states = Concurrent::Map.new
              @state_mutex = Mutex.new
              @dormant_weight_tracker = Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
              reconcile_and_refresh
            end

            def tick_refresh = reconcile_and_refresh

            # Re-scans configured instances every tick so instances configured
            # after boot appear without a restart and instances removed from
            # settings are retired from the registry. Instances claimed THIS
            # tick are not refreshed again in the same pass — their initial
            # probe just ran; refresh and cadence probes start next tick.
            # @instance_states is keyed by the CONFIG NAME (Symbol): identity
            # is the name, so two names pointing at the same endpoint are
            # distinct, independently-managed instances.
            def reconcile_and_refresh
              configured = configured_instances
              existing = @state_mutex.synchronize { @instance_states.keys }
              add_newly_configured_instances(configured: configured)
              remove_unconfigured_instances(configured: configured)
              states = @state_mutex.synchronize { @instance_states.each_pair.to_a }
              states.each do |name, state|
                next unless existing.include?(name)

                refresh_instance(state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.refresh_instance',
                                    instance_id: state[:instance_id])
              end
              observe_dormant_weights
            end

            def add_newly_configured_instances(configured:)
              configured.each do |name, instance_cfg|
                tracked = @state_mutex.synchronize { @instance_states.key?(name.to_sym) }
                next if tracked

                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def remove_unconfigured_instances(configured:)
              states = @state_mutex.synchronize { @instance_states.each_pair.to_a }
              states.each do |name, state|
                next if configured.key?(name)

                drop_instance(name: name, state: state)
              end
            end

            # Starts the readiness probe and settles it: on success activates
            # the current offerings (sequence 0 — valid only while the scope
            # is still :initializing), on failure records it and the instance
            # stays :initializing for the next tick's retry.
            def settle_initial_readiness(state:)
              instance_id = state[:instance_id]
              physical_id = state[:physical_id]
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, physical_id: physical_id,
                publisher_token: state[:publisher_token]
              )
              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              if readiness.ready?
                Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
                  settings: Legion::Settings,
                  instance_id: instance_id,
                  state_key: state[:name],
                  state: state,
                  states: @instance_states,
                  mutex: @state_mutex,
                  probe_token: probe_token,
                  activate: method(:activate_weight_snapshot),
                  activation_sequence: ->(tracked) { tracked.fetch(:sequence) }
                )
              else
                tracked = @state_mutex.synchronize { @instance_states[state[:name]].equal?(state) }
                return false unless tracked

                publisher.readiness_failed(
                  instance_id: instance_id, physical_id: physical_id,
                  probe_token: probe_token, reason: readiness.reason
                )
                true
              end
            end

            def refresh_instance(state:)
              published = @state_mutex.synchronize { state[:published] }
              if published
                replace_offerings_if_changed(state: state)
                run_cadence_probe(state: state)
              else
                retry_initial_activation(state: state)
              end
            end

            # An instance that failed initial readiness stays :initializing —
            # readiness_succeeded and replace_instance_snapshot both refuse to
            # operate on an :initializing scope, so without this re-activation
            # path a transient outage at boot pins the instance for the process
            # lifetime. Re-probe each tick and activate once readiness passes.
            def retry_initial_activation(state:)
              replace_offerings_if_changed(state: state)
              settled = settle_initial_readiness(state: state)
              sync_display_health(state: state) if settled
            end
          end

          # SSOT v3 periodic discovery actor for Ollama provider instances.
          # Claims operator-configured instances, discovers models via
          # /api/tags, probes readiness via /api/tags (non-inference), and
          # publishes complete OfferingDraft snapshots through
          # Inventory::Publisher. Recovers instances that fail initial
          # readiness and supports coalesced reactive probes after
          # dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include EvidenceBuilder
            include ValueEvidenceBuilder
            include ModelDiscovery
            include ConfigResolver
            include HttpClient
            include ProbeRunner
            include HealthChecker
            include OfferingComparison
            include DisplayHealth
            include InstanceComponents
            include WeightPublication
            include InstanceLifecycle

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            # The registered discovery interval lives under discovery
            # (provider_settings nests discovery.interval_seconds). Never
            # return nil — a nil execution_interval makes the TimerTask fire
            # exactly once and then stop, killing all refresh, probes, and
            # recovery.
            def time
              interval = settings.dig(:discovery, :interval_seconds)
              return interval if interval.is_a?(::Integer) && interval.positive?

              Legion::Extensions::Llm::Ollama.default_settings.dig(:discovery, :interval_seconds)
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.discovery_refresh.shutdown')
            end

            private

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
            end
          end

          # Callable wrapper for an Ollama provider instance. Implements the
          # fleet dispatch ops (chat/stream_chat/embed/count_tokens) by
          # delegating to a per-instance Ollama::Provider, plus the
          # disconnect and normalize_dispatch_error contracts required by
          # Inventory::CallableHandle and Routing::ProviderOutcome. Dispatch
          # errors propagate untouched so normalize_dispatch_error can
          # classify them.
          class OllamaCallable
            def initialize(instance_cfg:, logger:, provider: nil)
              @instance_cfg = instance_cfg
              @logger = logger
              @provider = provider
              @disconnected = false
            end

            def disconnected? = @disconnected

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @logger.debug { '[ollama][callable] disconnected' }
            end

            # Fleet and SelectionDispatch pass model as a RAW STRING (the
            # offering's model id). Ollama's render path is string-tolerant
            # (model.respond_to?(:id) ? model.id : model) for chat and embed,
            # embed places the model verbatim in the 05 §3 embedding artifact,
            # and count_tokens ignores it — so the model passes through
            # UNWRAPPED on every op. Wrapping a raw string in Model::Info here
            # would serialize a Data object into the wire payload or the
            # response object (D15 per-op rule); Model::Info instances pass
            # through unchanged as well.
            # 0.8.0 callable contract: messages is the positional canonical
            # Array (the base Provider funnel and the fleet worker both call
            # it that way); model: and the remaining params are kwargs.
            def chat(messages, model:, **rest)
              # Canonical boundary (N x N law): pipeline dispatch delivers
              # Canonical::Message objects only. Hash shapes are the bypass
              # class — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              provider.chat(messages, model: model, **rest)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              provider.stream_chat(messages, model: model, **rest, &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model: model, **rest)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              provider.count_tokens(messages: messages, model: model, **rest)
            end

            def normalize_dispatch_error(error:)
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: classify_dispatch_error(error: error),
                reason: dispatch_reason(error)
              )
            end

            private

            # Classification delegates to the base Provider contract
            # (Legion::Extensions::Llm::Provider#normalize_dispatch_error —
            # handles every Llm::*Error the ErrorMiddleware raises plus the
            # raw Faraday transport errors it does not wrap: connection
            # failure and timeout, the down-signals). The delegate is a
            # zero-config classifier shell: a Provider built WITH a base_url
            # probes endpoint reachability at construction, and the base
            # method is stateless. Provider-specific layering on top:
            #   1. An Ollama 5xx body reporting the model not loaded/loading
            #      is :model_not_ready (checked first).
            #   2. Raw Faraday HTTP status errors (which the base contract
            #      leaves as :provider_error) are refined by status.
            def classify_dispatch_error(error:)
              return :model_not_ready if model_not_ready?(error: error)

              base_kind = base_classifier.normalize_dispatch_error(error: error).kind
              return base_kind unless base_kind == :provider_error && faraday_status_error?(error)

              status_kind(dispatch_status(error))
            end

            def base_classifier
              @base_classifier ||= Legion::Extensions::Llm::Ollama::Provider.new({})
            end

            def faraday_status_error?(error)
              error.is_a?(Faraday::ClientError) || error.is_a?(Faraday::ServerError)
            end

            # §8 health firewall: Ollama emits no explicit flat
            # instance-unavailable dispatch signal (a dead server simply drops
            # the connection — that is the :connection_failure down-signal,
            # which the readiness probe then turns into an availability
            # transition). Status code alone (503/5xx) never maps to
            # :instance_unavailable — those are request-local conditions.
            def status_kind(status)
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              when 503, 529 then :overloaded
              when 400...500 then :invalid_request
              else :provider_error
              end
            end

            # Ollama reports model warmup in the response body ("model is not
            # loaded", "model ... loading"). Reads the body from every real
            # error shape: Llm::Error wraps a Faraday::Response, real Faraday
            # 2.x errors wrap a Faraday::Env (a Struct, NOT a Hash — an
            # is_a?(Hash) gate here is dead in production), and hand-built
            # spec errors may carry a plain response Hash.
            def model_not_ready?(error:)
              status = dispatch_status(error)
              return false unless status.is_a?(::Integer) && status >= 500

              response_body_string(error).to_s.match?(/model.{0,10}(not\s+(loaded|ready)|loading)/i)
            end

            def response_body_string(error)
              response = error.respond_to?(:response) ? error.response : nil
              return nil if response.nil?

              body = response.respond_to?(:body) ? response.body : (response[:body] if response.respond_to?(:[]))
              return body if body.is_a?(String)

              body && ::JSON.generate(body)
            end

            def dispatch_status(error)
              return error.response_status if error.respond_to?(:response_status) && error.response_status

              response = error.respond_to?(:response) ? error.response : nil
              return response.status if response.respond_to?(:status) && response.status
              return response[:status] if response.respond_to?(:[]) && response[:status]

              nil
            end

            def dispatch_reason(error)
              reason = error.message.to_s[0, 512]
              reason.empty? ? 'unknown dispatch error' : reason
            end

            def provider
              @provider ||= build_provider
            end

            def build_provider
              Legion::Extensions::Llm::Ollama::Provider.new(provider_config)
            end

            def provider_config
              cfg = @instance_cfg.to_h.transform_keys(&:to_sym)
              base_url = cfg[:base_url] || cfg[:endpoint]
              return {} unless base_url.is_a?(String) && !base_url.strip.empty?

              { base_url: base_url }
            end
          end
        end
      end
    end
  end
end
