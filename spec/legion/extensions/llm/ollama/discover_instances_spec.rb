# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ollama, '.discover_instances' do
  subject(:discover) { described_class.discover_instances }

  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }

  before do
    allow(credential_sources).to receive_messages(socket_open?: false, setting: nil)
  end

  it 'returns the local instance when the socket probe succeeds' do
    stub_socket_open(true)

    expect(discover).to include(local: local_instance_config)
  end

  it 'omits the local instance when the socket probe fails' do
    stub_socket_open(false)

    expect(discover).not_to have_key(:local)
  end

  it 'returns a settings-configured instance with tier :direct' do
    stub_settings(gpu_box: { base_url: 'http://gpu:11434' })

    expect(discover).to include(gpu_box: settings_instance_config('http://gpu:11434'))
  end

  it 'returns both local and settings instances when both are available' do
    stub_socket_open(true)
    stub_settings(remote: { base_url: 'http://remote:11434' })

    expect(discover.keys).to contain_exactly(:local, :remote)
    expect(discover[:local][:tier]).to eq(:local)
    expect(discover[:remote][:tier]).to eq(:direct)
  end

  it 'returns an empty hash when no local server and no settings exist' do
    expect(discover).to eq({})
  end

  def stub_socket_open(result)
    allow(credential_sources).to receive(:socket_open?)
      .with('127.0.0.1', 11_434, timeout: 0.1).and_return(result)
  end

  def stub_settings(instances)
    allow(credential_sources).to receive(:setting)
      .with(:extensions, :llm, :ollama, :instances)
      .and_return(instances)
  end

  def local_instance_config
    { base_url: 'http://127.0.0.1:11434', tier: :local, capabilities: %i[completion embedding vision] }
  end

  def settings_instance_config(base_url)
    { base_url: base_url, tier: :direct, capabilities: %i[completion embedding vision] }
  end
end
