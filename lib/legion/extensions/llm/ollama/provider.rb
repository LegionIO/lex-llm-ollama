# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Ollama
        # Ollama provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          class << self
            attr_writer :registry_publisher

            def slug = 'ollama'
            def local? = true
            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= Ollama.registry_publisher
            end
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

          def settings
            Ollama.default_settings
          end

          def api_base
            resolve_base_url || normalize_url(settings[:base_url] || '127.0.0.1:11434')
          end

          def config_base_url
            settings[:base_url]
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
            log.info { "listing running models from #{api_base}#{running_models_url}" }
            connection.get(running_models_url).body.fetch('models', [])
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'ollama.list_running_models')
            []
          end

          def readiness(live: false)
            log.info { "checking readiness live=#{live} at #{api_base}" }
            super.tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models
            log.info { "discovering models from #{api_base}#{models_url}" }
            super.tap do |models|
              log.info { "discovered #{models.size} model(s) from Ollama" }
              self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            end
          end

          def show_model(model)
            log.info { "fetching model details for #{model}" }
            connection.post(show_model_url, { model: model }).body
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'ollama.show_model')
            raise
          end

          def pull_model(model, stream: false)
            log.info { "pulling model #{model} stream=#{stream}" }
            connection.post(pull_url, { model: model, stream: stream }).body
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'ollama.pull_model')
            raise
          end

          private

          def ollama_keep_alive
            settings[:keep_alive]
          end

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            {
              model: model.id,
              messages: format_messages(messages),
              stream: stream,
              think: thinking ? true : nil,
              keep_alive: ollama_keep_alive,
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
              family = model.dig('details', 'family')
              caps = infer_capabilities(model.fetch('name'), family, Array(model['capabilities']))
              output_mods = embedding_model?(model.fetch('name'), family) ? [:embeddings] : [:text]

              Legion::Extensions::Llm::Model::Info.new(
                id: model.fetch('name'),
                name: model.fetch('name'),
                provider: provider,
                family: family,
                capabilities: caps,
                modalities_output: output_mods,
                metadata: model.merge('created_at' => model['modified_at'])
              )
            end
          end

          def infer_capabilities(name, family, api_caps)
            return api_caps.map(&:to_sym) unless api_caps.empty?

            if embedding_model?(name, family)
              [:embedding]
            else
              %i[completion streaming tools vision]
            end
          end

          def embedding_model?(name, family)
            name.to_s.match?(/embed|embedding/i) || family.to_s.match?(/bert|nomic/i)
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
