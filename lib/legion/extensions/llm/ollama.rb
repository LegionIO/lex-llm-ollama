# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/ollama/provider'
require 'legion/extensions/llm/ollama/version'

module Legion
  module Extensions
    module Llm
      # Ollama provider extension namespace.
      module Ollama
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :ollama

        def self.default_settings
          {
            enabled: false,
            base_url: '127.0.0.1:11434',
            default_model: 'qwen3.5:latest',
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 60,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end

        def self.discover_instances
          instances = {}

          if CredentialSources.socket_open?('127.0.0.1', 11_434, timeout: 0.1)
            instances[:local] = {
              base_url: 'http://127.0.0.1:11434',
              tier: :local,
              capabilities: %i[completion embedding vision]
            }
          end

          configured = CredentialSources.setting(:extensions, :llm, :ollama, :instances)
          if configured.is_a?(Hash)
            configured.each do |name, config|
              instances[name.to_sym] = config.merge(
                tier: :direct,
                capabilities: %i[completion embedding vision]
              )
            end
          end

          instances
        end
      end
    end
  end
end

Legion::Extensions::Llm::Ollama.register_discovered_instances
