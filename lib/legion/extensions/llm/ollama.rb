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
      end
    end
  end
end
