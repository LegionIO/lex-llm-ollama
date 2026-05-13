# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/ollama'
require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module Ollama
        module Runners
          # Runner entrypoint for Ollama fleet request execution.
          module FleetWorker
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              payload_keys = payload.respond_to?(:keys) ? payload.keys.join(',') : payload.class
              log.debug do
                "ollama fleet worker handing off request payload_keys=#{payload_keys} " \
                  "delivery=#{!delivery.nil?} properties=#{!properties.nil?}"
              end

              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
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
