# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/extensions/llm'

# Stub the LegionIO host-runtime pieces that are not available in the provider
# gem's spec environment before loading Ollama (the production host always
# loads them; a missing actor runtime must fail loud at require time — the
# production files raise LoadError, these stubs only satisfy that guard).
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        class Every
          def self.spec_stub? = true
        end
      end

      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end

    module Core; end unless const_defined?(:Core, false)

    module Helpers
      # The production LegionIO host provides Helpers::Lex, which auto-injects
      # log / settings / handle_exception / cache_* for extension classes.
      # In the spec environment, mix in the REAL legion-settings Helper so
      # `settings` runs the actual 1.4.2 resolution: the actor's
      # Legion::Extensions::Llm::Ollama::Actor::* namespace resolves to the
      # nested [:extensions][:llm][:ollama] node — the same live tree the
      # discovery path reads via CredentialSources.setting. The shared
      # Discovery::Pipeline (mixed into the runner module) and the base actor
      # call `log` and `handle_exception` on the includer, so the stand-in
      # provides both: the real Logging::Helper for `log`, and a logging-only
      # `handle_exception` that never re-raises (callers own `handled:`
      # semantics and re-raise explicitly — the pipeline re-raises programming
      # errors and CatalogFetchFailure after logging).
      module Lex
        include Legion::Settings::Helper
        include Legion::Logging::Helper

        def handle_exception(exception, level: :error, handled: true, **)
          log.public_send(level) do
            "[spec stand-in] exception=#{exception.class} handled=#{handled} message=#{exception.message}"
          end
        end
      end
    end
  end
end

require 'legion/extensions/llm/ollama'

# Load the shared example groups from the lex-llm gem's spec/ directory
# (spec/ ships in the gem but is NOT on the load path). Only the
# example-group files this suite consumes — the kit directory also contains
# lex-llm's own self-test specs, which must not run inside a provider gem's
# suite.
if Gem.loaded_specs['lex-llm']
  # The kit loads by EXPLICIT file list (kit contract, 09 §5 — the documented
  # **/*.rb glob loads lex-llm's own self-test specs, which LoadError outside
  # the repo). conformance.rb is the Canonical::Conformance fixture module;
  # the *_examples.rb files are the shared example groups; ssot_contract_*
  # carries the B/F/R boundary groups (B1/B2 run in this suite against the
  # real callable boundary).
  %w[
    conformance.rb
    canonical_type_examples.rb
    client_translator_examples.rb
    provider_translator_examples.rb
    provider_tool_rendering_examples.rb
    ssot_contract_examples.rb
    ssot_provider_examples.rb
  ].each do |kit_file|
    path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path,
                     'spec/legion/extensions/llm/conformance', kit_file)
    require path if File.exist?(path)
  end
end

# The discovery path (Ollama.configured_instances) reads the live
# Legion::Settings tree via CredentialSources.setting; ensure the ollama
# node exists for specs to populate.
if defined?(Legion::Settings)
  settings_tree = Legion::Settings.loader.settings
  settings_tree[:extensions][:llm] ||= {}
  settings_tree[:extensions][:llm][:ollama] ||= {}
end

Legion::Logging.setup(
  level: 'debug',
  format: :text,
  async: false,
  trace: false,
  trace_size: 0,
  extended: false,
  log_file: File::NULL,
  log_stdout: false,
  include_pid: false,
  color: false
)
