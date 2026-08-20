# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/ollama/runners/fleet_worker'

FleetWorkerSpecDelivery = Class.new unless defined?(FleetWorkerSpecDelivery)
FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::Ollama::Runners::FleetWorker do
  # The Subscription dispatch path invokes handle_fleet_request(**message)
  # where message is the fleet request envelope merged with transport
  # metadata; the responder parses the envelope out of that hash.
  let(:message) do
    {
      request_id: 'req-1', provider: 'ollama', provider_instance: 'local',
      routing_key: 'llm.ollama.fleet_worker.#', message_id: 'msg-1'
    }
  end
  let(:delivery) { instance_double(FleetWorkerSpecDelivery) }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }

  it 'delegates fleet execution to the shared lex-llm responder helper with an explicit registry' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(**message, delivery: delivery, properties: properties)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: message.merge(delivery: delivery, properties: properties),
      provider_family: :ollama,
      registry: Legion::Extensions::Llm::Inventory::Registry,
      delivery: delivery,
      properties: properties
    )
  end

  it 'accepts the envelope-only kwargs shape (no transport metadata)' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    described_class.handle_fleet_request(**message)

    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: message,
      provider_family: :ollama,
      registry: Legion::Extensions::Llm::Inventory::Registry,
      delivery: nil,
      properties: nil
    )
  end
end
