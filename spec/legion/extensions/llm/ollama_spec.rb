# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ollama do
  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:ollama)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('http://localhost:11434')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end
end
