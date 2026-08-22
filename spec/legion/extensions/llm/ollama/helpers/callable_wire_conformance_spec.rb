# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ollama::Helpers::Callable do
  it 'renders Task-01 folded system content as the leading Ollama system message' do
    captured = []
    connection = Object.new
    connection.define_singleton_method(:post) do |path, payload, &request_block|
      captured << { path: path, payload: payload }
      request_block&.call(Struct.new(:headers).new({}))
      Struct.new(:body).new(
        {
          'model' => 'qwen3:8b',
          'message' => { 'role' => 'assistant', 'content' => 'ok' },
          'done' => true
        }
      )
    end
    connection.define_singleton_method(:close) { true }
    provider = Legion::Extensions::Llm::Ollama::Provider.new(base_url: 'http://127.0.0.1:11435')
    provider.instance_variable_set(:@connection, connection)
    callable = described_class.new(
      instance_cfg: { base_url: 'http://127.0.0.1:11435' },
      logger: Logger.new(File::NULL),
      provider: provider
    )
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'authoritative system'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    callable.chat(messages, model: 'qwen3:8b')

    expect(captured.one?).to be(true)
    expect(captured.first[:path]).to eq('/api/chat')
    expect(captured.first[:payload][:messages]).to eq(
      [
        { role: 'system', content: 'authoritative system' },
        { role: 'user', content: 'hello' }
      ]
    )
  ensure
    callable&.disconnect
  end
end
