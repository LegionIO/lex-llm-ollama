# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/ollama/translator'

RSpec.describe Legion::Extensions::Llm::Ollama::Translator do
  it_behaves_like 'a canonical provider translator', described_class
end
