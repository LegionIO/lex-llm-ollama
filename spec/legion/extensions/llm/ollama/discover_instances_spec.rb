# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ollama, '.discover_instances' do
  subject(:discover) { described_class.discover_instances }

  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }
  let(:synthetic_default) { described_class.default_settings.dig(:instances, :default) }

  before do
    allow(credential_sources).to receive(:setting).and_call_original
    allow(credential_sources).to receive(:setting)
      .with(:extensions, :llm, :ollama, :instances)
      .and_return(nil)
  end

  it 'normalizes configured instance endpoint aliases to base_url' do
    stub_settings(lab: { endpoint: 'http://lab:11434' })

    expect(discover[:lab]).to include(
      base_url: 'http://lab:11434',
      tier: :local,
      capabilities: {},
      provider_capabilities: { streaming: true }
    )
  end

  it 'supports multiple configured instances, each with its own endpoint' do
    stub_settings(
      alpha: { base_url: 'http://alpha:11434' },
      beta: { base_url: 'http://beta:11434' }
    )

    expect(discover.keys).to contain_exactly(:alpha, :beta)
    expect(discover[:alpha][:base_url]).to eq('http://alpha:11434')
    expect(discover[:beta][:base_url]).to eq('http://beta:11434')
  end

  # D3: the synthetic instances.default section (the extension's own instance
  # defaults, nested by provider_settings) is an unconfigured phantom while it
  # is unmodified — it must never be auto-registered.
  it 'skips the synthetic instances.default while it is the unmodified extension default' do
    stub_settings(default: synthetic_default)

    expect(discover).to eq({})
  end

  # InstanceKey reserves 'default' as an instance identity (lex-llm
  # foundation): a modified instances.default can never be registered under
  # its name, so it is skipped here — the actor and the fleet responder must
  # agree on the claimable set (D3).
  it 'skips a modified instances.default (default is a reserved instance identity)' do
    stub_settings(default: synthetic_default.merge(base_url: 'http://127.0.0.1:11500'))

    expect(discover).to eq({})
  end

  it 'skips instances with enabled: false' do
    stub_settings(gpu_box: { base_url: 'http://gpu:11434', enabled: false })

    expect(discover).to eq({})
  end

  it 'skips instances with no endpoint (no fallback identity)' do
    stub_settings(no_endpoint: { tier: :local })

    expect(discover).to eq({})
  end

  it 'returns an empty hash when no instances are configured (no phantom local instance)' do
    expect(discover).to eq({})
  end

  it 'never fabricates an instance from a port probe' do
    # The legacy discover_local_instance socket probe is gone: with no
    # configured instances, nothing is registered even if a server happens
    # to listen on 127.0.0.1:11434.
    allow(credential_sources).to receive(:socket_open?)

    expect(discover).to eq({})
    expect(credential_sources).not_to have_received(:socket_open?)
  end

  def stub_settings(instances)
    allow(credential_sources).to receive(:setting)
      .with(:extensions, :llm, :ollama, :instances)
      .and_return(instances)
  end
end
