# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/ollama/runners/fleet_worker'

FleetWorkerSpecDelivery = Class.new unless defined?(FleetWorkerSpecDelivery)
FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::Ollama::Runners::FleetWorker do
  let(:payload) { { request_id: 'req-1', provider: 'ollama', provider_instance: 'local' } }
  let(:delivery) { instance_double(FleetWorkerSpecDelivery) }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }
  let(:instances) { { local: { fleet: { respond_to_requests: true } } } }

  it 'uses the Legion logging helper for fleet handoff diagnostics' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
  end

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::Ollama).to receive(:discover_instances).and_return(instances)
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(payload, delivery:, properties:)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: payload,
      provider_family: :ollama,
      provider_class: Legion::Extensions::Llm::Ollama::Provider,
      provider_instances: satisfy { |resolver| resolver.call == instances },
      delivery: delivery,
      properties: properties
    )
  end
end
