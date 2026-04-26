# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/ollama/provider_settings'
require 'legion/extensions/llm/ollama/version'

module Legion
  module Extensions
    module Llm
      # Ollama provider extension namespace.
      module Ollama
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :ollama

        def self.default_settings
          ProviderSettings.build(
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
      end
    end
  end
end
