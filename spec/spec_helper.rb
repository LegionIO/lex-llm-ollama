# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/extensions/llm'
require 'legion/extensions/llm/ollama'

# Load conformance kit from installed lex-llm gem's spec/ directory.
# Per Phase 2 amended spec: spec/ ships in the gem; it is NOT on the load path.
lex_llm_spec = Gem.loaded_specs['lex-llm']
if lex_llm_spec
  kit_path = File.join(lex_llm_spec.full_gem_path, 'spec/legion/extensions/llm/conformance')
  if Dir.exist?(kit_path)
    Dir[File.join(kit_path, '**', '*.rb')].each do |f|
      require f
    rescue StandardError
      next
    end
  end
end

Legion::Logging.instance_variable_set(
  :@current_settings,
  {
    level: :fatal,
    async: false,
    trace: false,
    trace_size: 0,
    extended: false,
    log_file: nil,
    log_stdout: false,
    include_pid: false,
    color: false
  }.freeze
)
Legion::Logging.instance_variable_set(:@configuration_generation, Legion::Logging.configuration_generation + 1)
Legion::Logging.log.level = Logger::FATAL if Legion::Logging.respond_to?(:log)
