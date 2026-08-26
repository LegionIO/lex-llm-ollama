# frozen_string_literal: true

require 'uri'
require 'faraday'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/ollama/helpers/callable'
require 'legion/extensions/llm/ollama/provider'

module Legion
  module Extensions
    module Llm
      module Ollama
        module Runners
          # Ollama discovery runner: ONLY the Ollama-specific work. Reconcile,
          # claim, activate, probe (cadence + reactive), replace, weight
          # publication, dormant-weight tracking, and health display are all
          # mixed in from the shared Discovery::Pipeline. Weight is NOT computed
          # here — the shared WeightReconciler recomputes the write-time weight
          # from live settings at publish.
          #
          # Ollama is local (no auth). Its catalog is GET /api/tags -> body[:models]
          # with the model id under :name (not :id). Readiness is a non-inference
          # GET /api/tags. Per-model detail (context window, capabilities, embedding
          # dimensions) is optional enrichment from POST /api/show.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            # ── Ollama instance config / connection ───────────────────────────

            def catalog_base_url(instance_cfg:)
              (instance_cfg[:base_url] || instance_cfg[:endpoint]).to_s
            end

            def health_path = '/api/tags'

            # /api/tags lists models under :name, not :id.
            def model_id_from(model_data)
              (model_data[:name] || model_data['name']).to_s
            end

            # /api/tags -> body[:models] (not /v1/models -> body[:data]).
            def fetch_raw_models(instance_cfg:)
              conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg),
                                      instance_cfg: instance_cfg, timeout: 15, open_timeout: 5)
              response = conn.get('/api/tags')
              unless response.status.between?(
                200, 299
              )
                raise CatalogFetchFailure,
                      "ollama /api/tags returned HTTP #{response.status}"
              end

              Array(Legion::JSON.load(response.body).fetch(:models, []))
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Ollama::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # Secondary PHYSICAL id (dedup/diagnostics), not identity: the exact
            # host:port the operator configured. No host or port fallback (a
            # fallback physical id would mask a missing endpoint).
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
              handle_exception(e, level: :warn, handled: true, operation: 'ollama.runner.discovery.extract_host_port',
                                  url: url.to_s)
              raise
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────

            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = instance_cfg[:tier] || :local
              detail = fetch_model_detail_safe(model_name: model_id, instance_cfg: instance_cfg)
              embed_supported = embedding_model?(model_name: model_id, model_data: model_data)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_supported),
                capability_evidence: build_capability_evidence(model_name: model_id, model_data: model_data,
                                                               detail: detail),
                context_evidence: build_context_evidence(detail: detail),
                max_output_evidence: absent_value_evidence,
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(embed_supported: embed_supported,
                                                                                   detail: detail),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: absent_value_evidence,
                quota_domains: {},
                metadata: build_offering_metadata(model_name: model_id, model_data: model_data)
                          .merge(instance_id: instance_key.instance_id),
                publication_source: :provider_catalog
              )
            end

            private

            # Per-model detail is optional enrichment; a transport or
            # body-parse failure degrades that model's evidence to :unknown
            # without failing the discovery. Programming errors propagate.
            def fetch_model_detail_safe(model_name:, instance_cfg:)
              conn = build_detail_connection(base_url: catalog_base_url(instance_cfg: instance_cfg))
              response = conn.post('/api/show', Legion::JSON.dump({ model: model_name }))
              body = Legion::JSON.load(response.body)
              parse_model_detail(body: body)
            rescue Faraday::Error, Legion::JSON::ParseError => e
              handle_exception(e, level: :warn, operation: 'ollama.runner.discovery.fetch_model_detail',
                                  model: model_name)
              nil
            end

            def build_detail_connection(base_url:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                f.headers['Content-Type'] = 'application/json'
                f.adapter Faraday.default_adapter
              end
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

            # Authoritative operation evidence: an EMBEDDING model publishes
            # chat and stream_chat as :unsupported so a plain chat request cannot
            # misroute to an embedding instance, and a chat model publishes embed
            # as :unsupported.
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
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(model_name:, model_data:, detail:)
              evidence = {
                completion: cap_evidence(capability: :completion, status: :supported, source: :provider_implementation),
                streaming: cap_evidence(capability: :streaming, status: :supported, source: :provider_implementation)
              }
              evidence[:tools] = resolve_tools_evidence(detail: detail)
              evidence[:thinking] = resolve_thinking_evidence(detail: detail)
              evidence[:vision] = resolve_vision_evidence(model_data: model_data)
              if embedding_model?(model_name: model_name, model_data: model_data)
                evidence[:embedding] =
                  cap_evidence(capability: :embedding, status: :supported, source: :provider_implementation)
              end
              evidence
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
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

            def resolve_vision_evidence(model_data:)
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

            def build_context_evidence(detail:)
              return absent_value_evidence unless detail

              ctx = detail[:context_window]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: ctx,
                                                                      source: :provider_catalog)
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(embed_supported:, detail:)
              return absent_value_evidence unless embed_supported && detail

              dims = detail[:embedding_dimensions]
              if dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: dims.uniq.sort,
                                                                      source: :provider_catalog)
              else
                absent_value_evidence
              end
            end

            def build_model_revision_evidence(model_data:)
              digest = model_data[:digest] || model_data['digest']
              if digest.is_a?(String) && !digest.strip.empty?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: digest.strip,
                                                                      source: :provider_catalog)
              else
                absent_value_evidence
              end
            end

            def build_offering_metadata(model_name:, model_data:)
              meta = { raw_model: model_name }
              family = model_data.dig(:details, :family) || model_data.dig('details', 'family')
              meta[:family] = family.to_s if family
              size = model_data[:size] || model_data['size']
              meta[:size_bytes] = size if size.is_a?(Integer)
              meta
            end

            def absent_value_evidence
              @absent_value_evidence ||= Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                               source: :absent)
            end
          end
        end
      end
    end
  end
end
