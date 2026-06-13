# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/ollama/provider'
require 'legion/extensions/llm/ollama/translator'
require 'legion/extensions/llm/ollama/version'
require 'legion/logging/helper'

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
                capabilities: %i[chat stream_chat embed tools],
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

          discover_local_instance(instances)
          discover_configured_instances(instances)

          log.debug { "ollama discovery returning instance_count=#{instances.size}" }
          instances
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:base_url] ||= normalized.delete(:ollama_api_base)
          normalized[:base_url] ||= normalized.delete(:api_base)
          normalized[:base_url] ||= normalized.delete(:endpoint)
          normalized.compact
        end

        def self.discover_local_instance(instances)
          log.debug { 'ollama discovery probing local socket host=127.0.0.1 port=11434' }
          return unless CredentialSources.socket_open?('127.0.0.1', 11_434, timeout: 0.1)

          log.debug { 'ollama discovery found local socket instance' }
          instances[:local] = {
            base_url: 'http://127.0.0.1:11434',
            tier: :local,
            capabilities: %i[completion embedding vision]
          }
        end

        def self.discover_configured_instances(instances)
          configured = CredentialSources.setting(:extensions, :llm, :ollama, :instances)
          return unless configured.is_a?(Hash)

          log.debug { "ollama discovery loading configured instance_count=#{configured.size}" }
          configured.each do |name, config|
            instances[name.to_sym] = normalize_instance_config(config).merge(
              tier: :direct,
              capabilities: %i[completion embedding vision]
            )
          end
        end

        private_class_method :discover_local_instance, :discover_configured_instances
      end
    end
  end
end
