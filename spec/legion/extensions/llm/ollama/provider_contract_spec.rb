# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/ollama/provider'

RSpec.describe Legion::Extensions::Llm::Ollama::Provider do
  # 0.8.0 funnel law (08 F3): the base Provider defines the canonical
  # completion entry points (positional `messages` + kwargs). The gem must
  # inherit the funnel unchanged, and must not add positional canonical
  # arguments to the methods it does define.
  it 'inherits the 0.8.0 completion funnel from the base without redefining it' do
    %i[chat stream_chat complete].each do |method_name|
      owner = described_class.instance_method(method_name).owner
      expect(owner).to eq(Legion::Extensions::Llm::Provider),
                       "#{method_name} must be the base 0.8.0 funnel, not a gem redefinition"
    end
  end

  it 'does not expose positional canonical arguments on its own methods' do
    canonical_methods.each { |method_name| expect_keyword_compatible(method_name) }
  end

  def canonical_methods = %i[embed image discover_offerings health count_tokens]

  def expect_keyword_compatible(method_name)
    return unless described_class.method_defined?(method_name)

    params = described_class.instance_method(method_name).parameters
    expect(params).not_to include(%i[req messages]), "#{method_name} still has positional messages"
    expect(params).not_to include(%i[req text]), "#{method_name} still has positional text"
    expect(params).not_to include(%i[req prompt]), "#{method_name} still has positional prompt"
  end
end
