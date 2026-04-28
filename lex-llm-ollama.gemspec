# frozen_string_literal: true

require_relative 'lib/legion/extensions/llm/ollama/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-llm-ollama'
  spec.version       = Legion::Extensions::Llm::Ollama::VERSION
  spec.authors       = ['LegionIO']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'LegionIO LLM Ollama provider extension'
  spec.description   = 'Ollama provider integration for the LegionIO LLM routing framework.'
  spec.homepage      = 'https://github.com/LegionIO/lex-llm-ollama'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['documentation_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = `git ls-files -z`.split("\x0").reject { |file| file.match(%r{^(spec|test|features|tmp|coverage)/}) }
  spec.require_paths = ['lib']

  spec.add_dependency 'lex-llm', '>= 0.1.3'
end
