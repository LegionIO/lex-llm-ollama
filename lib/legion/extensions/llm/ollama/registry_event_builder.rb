# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ollama
        # Builds sanitized lex-llm registry envelopes for Ollama provider state.
        class RegistryEventBuilder # rubocop:disable Metrics/ClassLength
          include Legion::Logging::Helper if defined?(Legion::Logging::Helper)

          def readiness(readiness)
            registry_event_class.public_send(
              readiness[:ready] ? :available : :unavailable,
              provider_offering(readiness),
              runtime: runtime_metadata,
              health: readiness_health(readiness),
              metadata: readiness_metadata(readiness)
            )
          end

          def model_available(model, readiness:)
            registry_event_class.available(
              model_offering(model),
              runtime: runtime_metadata,
              health: model_health(readiness),
              metadata: model_metadata(model)
            )
          end

          private

          def provider_offering(readiness)
            {
              provider_family: :ollama,
              provider_instance: provider_instance,
              transport: :http,
              model: 'provider-readiness',
              usage_type: :inference,
              capabilities: [],
              health: readiness_health(readiness),
              metadata: { lex: :llm_ollama, provider_readiness: true }
            }
          end

          def model_offering(model)
            {
              provider_family: :ollama,
              provider_instance: provider_instance,
              transport: :http,
              model: model.id,
              usage_type: usage_type_for(model),
              capabilities: capabilities_for(model),
              limits: model_limits(model),
              metadata: model_metadata(model)
            }
          end

          def readiness_health(readiness)
            health = {
              ready: readiness[:ready] == true,
              status: readiness[:ready] ? :available : :unavailable,
              checked: readiness.dig(:health, :checked) != false
            }
            add_readiness_error(health, readiness[:health])
          end

          def add_readiness_error(health, source)
            error = source.is_a?(Hash) ? source : {}
            error_class = error[:error] || error['error']
            error_message = error[:message] || error['message']
            health[:error_class] = error_class if error_class
            health[:error] = error_message if error_message
            health
          end

          def model_health(readiness)
            ready = readiness.fetch(:ready, true) == true
            { ready:, status: ready ? :available : :degraded }
          end

          def readiness_metadata(readiness)
            {
              extension: :lex_llm_ollama,
              provider: :ollama,
              configured: readiness[:configured] == true,
              live: readiness[:live] == true
            }
          end

          def model_metadata(model)
            metadata = model.metadata || {}
            {
              extension: :lex_llm_ollama,
              provider: :ollama,
              model_name: model.name,
              family: metadata.dig('details', 'family'),
              parameter_size: metadata.dig('details', 'parameter_size'),
              quantization_level: metadata.dig('details', 'quantization_level')
            }.compact
          end

          def runtime_metadata
            { node: provider_instance }
          end

          def model_limits(model)
            context_window = model.metadata&.dig('model_info', 'general.context_length') ||
                             model.metadata&.dig('model_info', "#{model_family(model)}.context_length")
            { context_window: context_window }.compact
          end

          def capabilities_for(model)
            configured = Array(model.capabilities).map(&:to_sym)
            return configured unless configured.empty?

            usage_type_for(model) == :embedding ? [:embedding] : %i[chat streaming tools vision]
          end

          def usage_type_for(model)
            return :embedding if model.id.to_s.match?(/embed|embedding/i)

            family = model_family(model).to_s
            family.match?(/bert|nomic/i) ? :embedding : :inference
          end

          def model_family(model)
            model.metadata&.dig('details', 'family') || model.metadata&.dig(:details, :family)
          end

          def provider_instance
            configured_node = (::Legion::Settings.dig(:node, :canonical_name) if defined?(::Legion::Settings))
            value = configured_node.to_s.strip
            value.empty? ? :ollama : value.to_sym
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'ollama.registry.provider_instance')
            :ollama
          end

          def registry_event_class
            ::Legion::Extensions::Llm::Routing::RegistryEvent
          end
        end
      end
    end
  end
end
