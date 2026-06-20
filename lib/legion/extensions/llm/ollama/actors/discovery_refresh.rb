# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Ollama
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            REFRESH_INTERVAL = 1800

            def self.every_seconds = 60

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return REFRESH_INTERVAL unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :ollama, :discovery_interval) || REFRESH_INTERVAL
            end

            def scope_key(**)
              { provider: :ollama }
            end

            def compute_lanes_for_scope(**)
              return [] unless defined?(Legion::LLM::Call::Registry)

              lanes = []
              ollama_instances.each do |instance|
                collect_lanes_for_instance(instance, lanes)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true,
                                    operation: 'ollama.discovery_refresh.compute_lanes',
                                    instance: instance[:instance])
              end
              lanes
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'ollama.discovery_refresh.compute_lanes_for_scope')
              []
            end

            def credential_hash(**)
              settings = ollama_settings
              Digest::SHA256.hexdigest(settings[:api_key].to_s + settings[:instances].to_s)[0, 16]
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'ollama.discovery_refresh.credential_hash')
              'unknown'
            end

            def manual(**)
              tick if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher) &&
                      respond_to?(:tick, true)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'ollama.actor.discovery_refresh')
            end

            private

            def ollama_instances
              Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :ollama
              end
            end

            def collect_lanes_for_instance(instance, lanes)
              adapter = instance[:adapter]
              return unless adapter.respond_to?(:discover_offerings)

              Array(adapter.discover_offerings(live: true)).each do |raw_offering|
                offering = offering_to_hash(raw_offering)
                next unless offering

                model = offering[:model] || offering['model']
                next unless model

                lane = build_lane(offering, instance)
                lanes << lane
                lanes << fleet_lane(lane, instance) if emit_fleet_lane?(lane)
              end
            end

            def offering_to_hash(offering)
              return nil if offering.nil?
              return offering if offering.is_a?(Hash)

              hash = offering.to_h
              hash[:type] ||= hash[:usage_type]
              hash[:enabled] = offering.respond_to?(:enabled?) ? offering.enabled? : true
              hash
            end

            def build_lane(offering, instance)
              instance_id  = instance[:instance] || instance[:instance_id] || instance[:id]
              raw_tier     = offering[:tier] || :local
              offer_type   = offering[:type]
              type         = %i[embed embedding].include?(offer_type) ? :embedding : :inference
              capabilities = normalize_capabilities(offering[:capabilities] || [])
              model        = offering[:model] || offering['model']

              lane_id = Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                tier: raw_tier, provider_family: :ollama,
                instance_id: instance_id, type: type, model: model
              )

              {
                id: lane_id,
                tier: raw_tier,
                provider_family: :ollama,
                instance_id: instance_id,
                model: model,
                canonical_model_alias: offering[:canonical_model_alias] || offering[:name],
                type: type,
                capabilities: capabilities,
                limits: offering[:limits] || {},
                enabled: offering.fetch(:enabled, true),
                cost: offering[:cost] || {}
              }
            end

            def emit_fleet_lane?(lane)
              return false unless lane[:type] == :inference

              ollama_settings&.dig(:fleet, :dispatch, :enabled)
            end

            def fleet_lane(lane, instance)
              fleet_id = Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                tier: :fleet, provider_family: :ollama,
                instance_id: instance[:instance] || instance[:instance_id],
                type: lane[:type], model: lane[:model]
              )
              lane.merge(id: fleet_id, tier: :fleet)
            end

            def normalize_capabilities(caps)
              # Inventory::Capabilities lives in lex-llm; the previous fallback (`return []
              # unless defined?(...)`) silently swallowed every capability the operator
              # declared via enable_thinking/enable_tools when the constant wasn't loaded.
              # Always normalize through the shared vocabulary so aliases collapse.
              if defined?(Legion::Extensions::Llm::Inventory::Capabilities)
                Legion::Extensions::Llm::Inventory::Capabilities.normalize(caps)
              else
                Array(caps).compact.map(&:to_sym).uniq
              end
            end

            def ollama_settings
              Legion::Settings.dig(:extensions, :llm, :ollama)
            rescue StandardError
              {}
            end
          end
        end
      end
    end
  end
end
