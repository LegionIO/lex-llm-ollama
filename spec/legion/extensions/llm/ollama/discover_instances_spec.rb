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
  # is unmodified — it must never be auto-registered. The skip warn fires
  # exactly once per boot (not every discovery tick): the first skip is the
  # operator signal, the rest is steady state.
  it 'skips the synthetic instances.default while it is the unmodified extension default' do
    # The throttle flag is process-wide (module singleton) — reset it so this
    # spec is order-independent of any earlier skip in the same process.
    described_class.instance_variable_set(:@unconfigured_default_warned, false)
    stub_settings(default: synthetic_default)

    expect(described_class.discover_instances).to eq({})
    # First skip: the operator signal — the throttle latches.
    expect(described_class.instance_variable_get(:@unconfigured_default_warned)).to be(true)

    # Later ticks: the skip repeats silently (no per-tick WARN spam).
    expect(described_class.discover_instances).to eq({})
    expect(described_class.instance_variable_get(:@unconfigured_default_warned)).to be(true)
    expect(described_class.discover_instances).to eq({})
    expect(described_class.instance_variable_get(:@unconfigured_default_warned)).to be(true)
  end

  # A configured (non-template) instances.default — a real operator entry
  # with real values — is NOT the synthetic phantom: v2 parity, 'default'
  # accepted as a plain instance label. The provider layer passes it to the
  # claim path; whether the foundation accepts the name is a lex-llm
  # InstanceKey contract, not a provider-layer decision (asserted on the
  # discover/claimable set, not an end-to-end claim).
  it 'passes a configured (non-template) instances.default to the claim path' do
    stub_settings(default: synthetic_default.merge(base_url: 'http://127.0.0.1:11500'))

    expect(discover).to have_key(:default)
    expect(discover[:default][:base_url]).to eq('http://127.0.0.1:11500')
    expect(discover[:default]).to include(
      capabilities: {},
      provider_capabilities: { streaming: true }
    )
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
