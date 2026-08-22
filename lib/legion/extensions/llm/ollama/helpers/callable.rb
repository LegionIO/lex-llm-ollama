# frozen_string_literal: true

require 'json'

require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/ollama/provider'

module Legion
  module Extensions
    module Llm
      module Ollama
        module Helpers
          # Callable wrapper for an Ollama provider instance. Implements the
          # fleet dispatch ops (chat/stream_chat/embed/count_tokens) by delegating
          # to a per-instance Ollama::Provider, plus the disconnect and
          # normalize_dispatch_error contracts required by Inventory::CallableHandle
          # and Routing::ProviderOutcome. Dispatch errors propagate untouched so
          # normalize_dispatch_error can classify them.
          class Callable
            # Keys the base Provider exposes as named kwargs for the completion
            # operations. Anything else the fleet passes (sampling scalars,
            # `temperature` — a Canonical::Params member, 05 O4) is folded into
            # Canonical::Params at the dispatch boundary.
            COMPLETION_NAMED_KEYS = %i[tools schema thinking tool_prefs headers].freeze
            EMBED_NAMED_KEYS = %i[dimensions headers].freeze

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
            # UNWRAPPED on every op.
            # 0.8.0 callable contract: chat/stream_chat take the rehydrated
            # message array positionally (WorkerExecution dispatch shape);
            # count_tokens takes the messages: kwarg (worker_execution.rb);
            # the Selection-derived model is a bare String.
            def chat(messages, model:, **rest)
              # Canonical boundary (N x N law): pipeline dispatch delivers
              # Canonical::Message objects only. Hash shapes are the bypass
              # class — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.chat(messages, model: model, params: canonical_params(params), **named)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.stream_chat(messages, model: model, params: canonical_params(params), **named, &)
            end

            def embed(text:, model:, **rest)
              named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
              provider.embed(text: text, model: model, params: params, **named)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              _named, params = split_fleet_kwargs(rest, [])
              provider.count_tokens(messages: messages, model: model, params: params)
            end

            def normalize_dispatch_error(error:)
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: classify_dispatch_error(error: error),
                reason: dispatch_reason(error)
              )
            end

            private

            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end

            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
            end

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
            # the connection — that is the :connection_failure down-signal, which
            # the readiness probe then turns into an availability transition).
            # Status code alone (503/5xx) never maps to :instance_unavailable.
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
