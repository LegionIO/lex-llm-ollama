# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/ollama'

module Legion
  module Extensions
    module Llm
      module Ollama
        module Runners
          # Runner entrypoint for Ollama fleet request execution.
          #
          # The Subscription dispatch path invokes this as
          # runner_class.send(fn, **message) where message is the fleet
          # request envelope merged with transport metadata (routing_key,
          # message_id, headers, ...). The responder parses the envelope out
          # of that hash; unknown keys are inert. Fleet protocol v3: exact
          # execution resolves the callable from the SSOT registry (the
          # legacy provider-object path is gone).
          module FleetWorker
            module_function

            def handle_fleet_request(**opts)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: opts,
                provider_family: Ollama::PROVIDER_FAMILY,
                registry: Legion::Extensions::Llm::Inventory::Registry,
                delivery: opts[:delivery],
                properties: opts[:properties]
              )
            end
          end
        end
      end
    end
  end
end
