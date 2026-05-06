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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://127.0.0.1:11434',
              default_model: 'qwen3.5:latest',
              tier: :local,
              transport: :http,
              credentials: {},
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 1 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed],
                lanes: [],
                concurrency: 1,
                queue_suffix: nil
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
              instances[name.to_sym] = normalize_instance_config(config).merge(
                tier: :direct,
                capabilities: %i[completion embedding vision]
              )
            end
          end

          instances
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:base_url] ||= normalized.delete(:ollama_api_base)
          normalized[:base_url] ||= normalized.delete(:api_base)
          normalized[:base_url] ||= normalized.delete(:endpoint)
          normalized.compact
        end
      end
    end
  end
end
