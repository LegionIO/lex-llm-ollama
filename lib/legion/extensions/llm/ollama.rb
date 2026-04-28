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

        PROVIDER_FAMILY = :ollama

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://localhost:11434',
              tier: :local,
              transport: :http,
              usage: { inference: true, embedding: true },
              limits: { concurrency: 1 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Ollama::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Ollama::Provider)
