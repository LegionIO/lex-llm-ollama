# frozen_string_literal: true

require 'legion/llm/fleet/provider_responder'
require 'legion/extensions/llm/ollama/provider'

module Legion
  module Extensions
    module Llm
      module Ollama
        module Runners
          # Runner entrypoint for Ollama fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::LLM::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Ollama::PROVIDER_FAMILY,
                provider_class: Ollama::Provider,
                provider_instances: -> { Ollama.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
