# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/json'

module Legion
  module Extensions
    module Llm
      module Ollama
        # Ollama provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          class << self
            def slug = 'ollama'
            def local? = true
            def configuration_options = %i[ollama_api_base ollama_keep_alive]
            def configuration_requirements = []
            def capabilities = Capabilities
          end

          # Capability predicates for Ollama model offerings.
          module Capabilities
            module_function

            def chat?(_model) = true
            def streaming?(_model) = true
            def vision?(_model) = true
            def functions?(_model) = true
            def embeddings?(_model) = true
          end

          def api_base
            config.ollama_api_base || 'http://localhost:11434'
          end

          def completion_url = '/api/chat'
          def stream_url = '/api/chat'
          def models_url = '/api/tags'
          def running_models_url = '/api/ps'
          def show_model_url = '/api/show'
          def embedding_url(**) = '/api/embed'
          def pull_url = '/api/pull'
          def version_url = '/api/version'

          def list_running_models
            connection.get(running_models_url).body.fetch('models', [])
          end

          def show_model(model)
            connection.post(show_model_url, { model: model }).body
          end

          def pull_model(model, stream: false)
            connection.post(pull_url, { model: model, stream: stream }).body
          end

          private

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            {
              model: model.id,
              messages: format_messages(messages),
              stream: stream,
              think: thinking ? true : nil,
              keep_alive: config.ollama_keep_alive,
              format: schema_format(schema),
              options: { temperature: temperature }.compact,
              tools: format_tools(tools),
              tool_choice: tool_choice(tool_prefs)
            }.compact
          end

          def format_messages(messages)
            messages.map do |message|
              content = message.content
              payload = { role: message.role.to_s, content: format_content(content) }
              payload[:images] = encoded_attachments(content) if content.respond_to?(:attachments)
              payload[:tool_call_id] = message.tool_call_id if message.tool_result?
              payload
            end
          end

          def format_content(content)
            return content.format if content.is_a?(Legion::Extensions::Llm::Content::Raw)
            return content.text.to_s if content.respond_to?(:text)

            content.to_s
          end

          def encoded_attachments(content)
            content.attachments.map(&:encoded)
          end

          def schema_format(schema)
            return nil unless schema

            schema.respond_to?(:to_h) ? schema.to_h.fetch(:schema, schema.to_h) : schema
          end

          def format_tools(tools)
            return nil if tools.empty?

            tools.values.map do |tool|
              {
                type: 'function',
                function: {
                  name: tool.name,
                  description: tool.description,
                  parameters: tool.params_schema || { type: 'object', properties: {} }
                }
              }
            end
          end

          def tool_choice(tool_prefs)
            return nil unless tool_prefs

            tool_prefs[:choice] || tool_prefs['choice']
          end

          def parse_completion_response(response)
            body = response.body
            message = body.fetch('message', {})
            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: message['content'],
              model_id: body['model'],
              tool_calls: parse_tool_calls(message['tool_calls']),
              input_tokens: body['prompt_eval_count'],
              output_tokens: body['eval_count'],
              raw: body
            )
          end

          def build_chunk(data)
            message = data.fetch('message', {})
            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: message['content'],
              model_id: data['model'],
              input_tokens: data['prompt_eval_count'],
              output_tokens: data['eval_count'],
              raw: data
            )
          end

          def parse_tool_calls(tool_calls)
            return nil unless tool_calls

            tool_calls.to_h do |call|
              function = call.fetch('function', {})
              [
                function.fetch('name').to_sym,
                Legion::Extensions::Llm::ToolCall.new(
                  id: call['id'] || function['name'],
                  name: function['name'],
                  arguments: function['arguments'] || {}
                )
              ]
            end
          end

          def parse_list_models_response(response, provider, _capabilities)
            response.body.fetch('models', []).map do |model|
              Legion::Extensions::Llm::Model::Info.new(
                id: model.fetch('name'),
                name: model.fetch('name'),
                provider: provider,
                created_at: model['modified_at'],
                capabilities: Array(model['capabilities']),
                metadata: model
              )
            end
          end

          def render_embedding_payload(text, model:, dimensions:)
            { model: model, input: text, dimensions: dimensions }.compact
          end

          def parse_embedding_response(response, model:, text:)
            body = response.body
            vectors = if body.key?('embedding')
                        body['embedding']
                      elsif text.is_a?(Array)
                        body['embeddings']
                      else
                        body['embeddings']&.first
                      end

            Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model,
                                                   input_tokens: body['prompt_eval_count'].to_i)
          end
        end
      end
    end
  end
end
