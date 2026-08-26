# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/ollama/translator'

RSpec.describe Legion::Extensions::Llm::Ollama::Translator do
  subject(:translator) { described_class.new }

  let(:canonical) { Legion::Extensions::Llm::Canonical }

  it_behaves_like 'a canonical provider translator', described_class

  describe '#render_request thinking config' do
    let(:base_request_hash) do
      {
        messages: [{ role: 'user', content: 'hello' }],
        stream: false,
        metadata: { model: 'qwen3:8b' }
      }
    end

    it 'emits think: true when Thinking::Config is enabled' do
      thinking = canonical::Thinking::Config.build(enabled: true, effort: 'medium')
      request = canonical::Request.from_hash(base_request_hash.merge(thinking: thinking.to_h))
      wire = translator.render_request(request)

      expect(wire[:think]).to be(true)
    end

    it 'emits think: false when Thinking::Config is disabled' do
      thinking = canonical::Thinking::Config.build(enabled: false)
      request = canonical::Request.from_hash(base_request_hash.merge(thinking: thinking.to_h))
      wire = translator.render_request(request)

      expect(wire[:think]).to be(false)
    end

    it 'omits think key when no thinking config is set' do
      request = canonical::Request.from_hash(base_request_hash)
      wire = translator.render_request(request)

      expect(wire).not_to have_key(:think)
    end
  end

  describe '#options_for' do
    it 'does not reference max_thinking_tokens on Canonical::Params' do
      params = canonical::Params.build(temperature: 0.5)
      expect(params).not_to respond_to(:max_thinking_tokens)

      # Should not raise NoMethodError
      expect { translator.options_for(params) }.not_to raise_error
    end
  end
end
