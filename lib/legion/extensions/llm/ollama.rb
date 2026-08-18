# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/ollama/provider'
require 'legion/extensions/llm/ollama/translator'
require 'legion/extensions/llm/ollama/version'
require 'legion/logging/helper'
require 'legion/extensions/llm/ollama/actors/discovery_refresh'

module Legion
  module Extensions
    module Llm
      # Ollama provider extension namespace.
      module Ollama
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :ollama

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://127.0.0.1:11434',
              tier: :local,
              transport: :http,
              credentials: {},
              usage: { inference: true, image: false },
              limits: { concurrency: 1 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed tools]
              }
            }
          )
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end

        # Single source of truth for Ollama instance discovery. The SSOT
        # discovery actor and the fleet responder both read this: only
        # operator-configured instances, no port-scanning, no fabricated
        # instances, no tier override.
        def self.discover_instances
          configured_instances
        end

        def self.configured_instances
          instances = {}
          cfg_instances = CredentialSources.setting(:extensions, :llm, :ollama, :instances)
          return instances unless cfg_instances.is_a?(Hash)

          cfg_instances.each do |name, config|
            normalized = claimable_instance_config(name: name, config: config)
            instances[name.to_sym] = normalized unless normalized.nil?
          end

          log.debug { "ollama discovery returning instance_count=#{instances.size}" }
          instances
        end

        # Only instances the operator actually configured are claimable.
        # The synthetic instances.default section (provider_settings nests
        # the extension's own instance defaults there) is skipped with a
        # once-per-boot warn while it is still the unmodified extension
        # default — an unconfigured phantom must never be auto-registered,
        # and a localhost endpoint is never a fallback identity.
        def self.claimable_instance_config(name:, config:)
          return nil unless config.is_a?(Hash)

          normalized = normalize_instance_config(config)
          return nil if normalized[:enabled] == false

          unless normalized[:base_url].is_a?(String) && !normalized[:base_url].strip.empty?
            log.warn("[ollama][discovery] action=skip_instance instance=#{name} reason=missing_endpoint")
            return nil
          end

          normalized.merge(capabilities: {}, provider_capabilities: { streaming: true })
        end

        # The synthetic default is the extension's OWN registered instance
        # defaults (endpoint http://127.0.0.1:11434 + fleet/limits blocks),
        # deep-merged into instances.default by provider_settings. It is
        # "configured" only when the operator changed something.
        def self.unconfigured_default?(name:, normalized:)
          name.to_sym == :default && normalized == normalized_synthetic_default_instance
        end

        def self.normalized_synthetic_default_instance
          @normalized_synthetic_default_instance ||= normalize_instance_config(
            default_settings.dig(:instances, :default) || {}
          )
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:base_url] ||= normalized.delete(:ollama_api_base)
          normalized[:base_url] ||= normalized.delete(:api_base)
          normalized[:base_url] ||= normalized.delete(:endpoint)
          normalized[:tier] ||= :local
          normalized
        end
      end
    end
  end
end
