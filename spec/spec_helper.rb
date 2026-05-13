# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/extensions/llm/ollama'

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
