# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Ollama
        module Actor
          # SSOT v3 periodic discovery actor for Ollama provider instances.
          # Claims instances, discovers models via /api/tags, probes readiness
          # via /api/tags (non-inference), and publishes complete OfferingDraft
          # snapshots through Inventory::Publisher. Supports coalesced reactive
          # probes after dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            def self.every_seconds = 300

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              self.class.every_seconds
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

            # -- Publisher -------------------------------------------------------

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :ollama)
            end

            # -- Initial discovery -----------------------------------------------

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name:, instance_cfg:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = derive_instance_id(instance_cfg:)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :ollama, instance_id: instance_id
              )

              callable = OllamaCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id:)
              )

              publisher_token = publisher.claim_instance(
                instance_id: instance_id,
                callable: callable,
                probe_request_handle: probe_coordinator
              )

              offerings = discover_offerings_for_instance(instance_cfg:)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: publisher_token
              )

              readiness = check_readiness(instance_cfg:)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: publisher_token,
                  offerings: offerings,
                  sequence: 0,
                  probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end

              @instance_states[instance_id] = {
                name: name,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: callable,
                probe_coordinator: probe_coordinator,
                publisher_token: publisher_token,
                sequence: 0,
                offerings: offerings
              }
            end

            # -- Tick refresh ----------------------------------------------------

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id:, state:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(instance_cfg: state[:instance_cfg])

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token],
                  offerings: new_offerings,
                  sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id:, state:)
            end

            # -- Readiness probing -----------------------------------------------

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              report_probe_result(instance_id:, probe_token:, readiness:)
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_e
                handle_exception(finish_e, level: :warn, operation: 'ollama.actor.cadence_probe.finish_probe',
                                           instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'ollama.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id:, probe_token:, readiness:)
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => finish_e
                handle_exception(finish_e, level: :warn, operation: 'ollama.actor.reactive_probe.finish_probe',
                                           instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'ollama.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.probe_enqueue',
                                    instance_id: instance_id)
                false
              end
            end

            # -- Readiness check (safe, non-inference) ---------------------------

            def check_readiness(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:base_url] || instance_cfg[:endpoint])
              conn = build_readiness_connection(base_url: base_url)
              response = conn.get('/api/tags')
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              handle_exception(e, level: :warn, handled: true, operation: 'ollama.actor.check_readiness',
                                  base_url: base_url)
              readiness_failure(reason: "Ollama /api/tags connection failed: #{e.message}", error: e)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'ollama.actor.check_readiness',
                                  base_url: base_url)
              readiness_failure(reason: "Ollama /api/tags error: #{e.message}", error: e)
            end

            def build_readiness_from_response(response:, base_url:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Ollama /api/tags returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false,
                reason: reason,
                metadata: { error_class: error.class.name }
              )
            end

            # -- Model discovery -------------------------------------------------

            def discover_offerings_for_instance(instance_cfg:)
              models = fetch_models(instance_cfg: instance_cfg)

              models.filter_map do |model_data|
                model_name = (model_data[:name] || model_data['name']).to_s
                next if model_name.empty?

                build_offering_draft(
                  model_name: model_name, model_data: model_data, instance_cfg: instance_cfg
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:base_url] || instance_cfg[:endpoint])
              conn = build_api_connection(base_url: base_url)
              response = conn.get('/api/tags')
              body = Legion::JSON.load(response.body)
              body.fetch(:models, [])
            end

            def build_offering_draft(model_name:, model_data:, instance_cfg:)
              tier = instance_cfg[:tier] || :local
              detail = fetch_model_detail_safe(model_name: model_name, instance_cfg: instance_cfg)
              embed_supported = embedding_model?(model_name: model_name, model_data: model_data)

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
                metadata: build_offering_metadata(model_name: model_name, model_data: model_data),
                publication_source: :provider_catalog
              )
            end

            # -- Operation evidence ----------------------------------------------

            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              embed_status = embed_supported ? :supported : :unsupported

              {
                chat: op_evidence(operation: :chat, status: :supported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: :supported, observed_at: now),
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

            # -- Capability evidence ---------------------------------------------

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

            # -- Value evidence builders -----------------------------------------

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

            # -- Embedding detection ---------------------------------------------

            def embedding_model?(model_name:, model_data:)
              caps = model_data[:capabilities] || model_data['capabilities']
              return true if caps.is_a?(Array) && (caps.include?('embedding') || caps.include?(:embedding))

              model_name.to_s.match?(/embed/i)
            end

            # -- Model detail fetching -------------------------------------------

            def fetch_model_detail_safe(model_name:, instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:base_url] || instance_cfg[:endpoint])
              conn = build_api_connection(base_url: base_url)
              response = conn.post('/api/show', Legion::JSON.dump({ model: model_name }))
              body = Legion::JSON.load(response.body)
              parse_model_detail(body: body)
            rescue StandardError => e
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

            # -- Offering metadata -----------------------------------------------

            def build_offering_metadata(model_name:, model_data:)
              meta = { raw_model: model_name }
              family = model_data.dig(:details, :family) || model_data.dig('details', 'family')
              meta[:family] = family.to_s if family
              size = model_data[:size] || model_data['size']
              meta[:size_bytes] = size if size.is_a?(Integer)
              meta
            end

            # -- Instance ID derivation ------------------------------------------

            def derive_instance_id(instance_cfg:)
              base_url = instance_cfg[:base_url] || instance_cfg[:endpoint] || 'http://127.0.0.1:11434'
              extract_host_port(url: base_url)
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host || '127.0.0.1'
              port = uri.port || 11_434
              "#{host}:#{port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, operation: 'ollama.actor.extract_host_port', url: url)
              raise
            end

            # -- Graceful shutdown -----------------------------------------------

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'ollama.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end

            # -- Configuration ---------------------------------------------------

            def configured_instances
              instances = {}

              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                end
              end

              # Auto-discover local Ollama if no instances configured
              if instances.empty?
                instances[:local] = {
                  base_url: settings[:endpoint],
                  tier: :local
                }
              end

              instances
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              normalized[:base_url] ||= normalized.delete(:ollama_api_base)
              normalized[:base_url] ||= normalized.delete(:api_base)
              normalized[:base_url] ||= normalized.delete(:endpoint)
              normalized[:tier] ||= :local
              normalized
            end

            # -- HTTP connections -------------------------------------------------

            def normalize_api_base(url)
              (url || 'http://127.0.0.1:11434').to_s
            end

            def build_readiness_connection(base_url:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 5
                f.options.open_timeout = 3
                f.adapter Faraday.default_adapter
              end
            end

            def build_api_connection(base_url:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                f.headers['Content-Type'] = 'application/json'
                f.adapter Faraday.default_adapter
              end
            end
          end

          # Callable wrapper for an Ollama provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class OllamaCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[ollama][callable] disconnected' }
            end

            def chat(model:, **)
              { role: 'assistant', content: 'response', model: model }
            end

            def stream_chat(model:, **)
              { role: 'assistant', content: 'streamed', model: model }
            end

            def embed(model:, **)
              { embedding: [0.0], model: model }
            end

            def count_tokens(model:, **)
              { token_count: 0, model: model }
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]

              kind = case error
                     when Faraday::ConnectionFailed
                       :connection_failure
                     when Faraday::TimeoutError
                       :timeout
                     when Faraday::ClientError
                       classify_client_error(error: error)
                     when Faraday::ServerError
                       classify_server_error(error: error)
                     when Legion::Extensions::Llm::OverloadedError
                       :overloaded
                     when Legion::Extensions::Llm::RateLimitError
                       :rate_limited
                     else
                       :provider_error
                     end

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/5xx as instance_unavailable by status alone.
              # Only an explicit flat Ollama service/instance-unavailable response
              # would justify instance_unavailable. Ollama does not produce such a
              # distinct signal; everything else is request-local.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503
                model_not_ready_body?(error: error) ? :model_not_ready : :overloaded
              else :provider_error
              end
            end

            def model_not_ready_body?(error:)
              body = error.respond_to?(:response_body) ? error.response_body.to_s : ''
              body.match?(/model.{0,10}(not\s+(loaded|ready)|loading)/i)
            end
          end
        end
      end
    end
  end
end
