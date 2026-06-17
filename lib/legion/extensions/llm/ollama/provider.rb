# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module Ollama
        # Ollama provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Logging::Helper

          class << self
            attr_writer :registry_publisher

            def slug = 'ollama'
            def local? = true
            def default_transport = :http
            def default_tier = :local
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

          def translator
            @translator ||= Translator.new(config: config)
          end

          def api_base
            resolve_base_url || normalize_url(settings[:base_url] || settings[:endpoint] || 'http://127.0.0.1:11434')
          end

          def config_base_url
            config.respond_to?(:base_url) ? config.base_url : settings[:base_url]
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
            log.debug { "ollama provider listing running models endpoint=#{api_base}#{running_models_url}" }
            connection.get(running_models_url).body.fetch('models', [])
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'ollama.list_running_models')
            []
          end

          def readiness(live: false)
            log.debug { "ollama provider checking readiness live=#{live} endpoint=#{api_base}" }
            super.tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models
            log.debug { "ollama provider discovering models endpoint=#{api_base}#{models_url}" }
            super.tap do |models|
              log.debug { "ollama provider discovered model_count=#{models.size}" }
              self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            end
          end

          def show_model(model)
            log.debug { "ollama provider fetching model details model=#{model}" }
            connection.post(show_model_url, { model: model }).body
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'ollama.show_model')
            raise
          end

          def fetch_model_detail(model_name)
            raw = show_model(model_name)
            context_window = extract_context_window(raw)
            { context_window: context_window, capabilities: extract_capabilities(raw) }.compact
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'ollama.fetch_model_detail',
                                model: model_name)
            nil
          end

          def pull_model(model, stream: false)
            log.debug { "ollama provider pulling model=#{model} stream=#{stream}" }
            log.info { "pulling model #{model} stream=#{stream}" }
            connection.post(pull_url, { model: model, stream: stream }).body
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'ollama.pull_model')
            raise
          end

          def discover_offerings(live: false, **)
            log.debug do
              "ollama provider discovering offerings live=#{live} cached_model_count=#{Array(@cached_models).size}"
            end
            running_ids = live ? running_model_ids : []
            offerings = resolve_models(live).filter_map do |model_info|
              next unless model_allowed?(model_info.id)

              offering_from_model(model_info, loaded: running_ids.include?(model_info.id.to_s))
            end
            log.debug { "ollama provider built offering_count=#{offerings.size} live=#{live}" }
            offerings
          rescue Faraday::ConnectionFailed => e
            log.warn("[ollama] instance=#{provider_instance_id} unreachable: #{e.message}")
            []
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'ollama.discover_offerings',
                                backtrace_limit: 3)
            []
          end

          CONTEXT_WINDOWS = {
            'qwen3' => 128_000,
            'qwen2.5' => 128_000,
            'llama3' => 128_000,
            'llama3.1' => 128_000,
            'llama3.2' => 128_000,
            'llama3.3' => 128_000,
            'gemma2' => 8_192,
            'gemma3' => 128_000,
            'mistral' => 128_000,
            'deepseek' => 128_000,
            'phi3' => 128_000,
            'phi4' => 16_384,
            'command-r' => 128_000,
            'codellama' => 16_384,
            'nomic-embed' => 8_192,
            'mxbai-embed' => 512,
            'snowflake' => 512,
            'bge' => 512
          }.freeze

          private

          def resolve_models(live)
            if live
              @cached_models = list_models
            else
              Array(@cached_models)
            end
          end

          def running_model_ids
            Array(list_running_models).filter_map do |m|
              m['name'] || m[:name] || m['model'] || m[:model]
            end.map(&:to_s)
          end

          def offering_from_model(model_info, loaded: false)
            policy = resolve_capability_policy(model_info)
            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :ollama,
              instance_id: config.respond_to?(:instance_id) ? config.instance_id : :default,
              transport: offering_transport,
              tier: offering_tier,
              model: model_info.id,
              usage_type: offering_usage_type(model_info),
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: offering_limits(model_info),
              metadata: offering_metadata(model_info).merge(loaded: loaded)
            )
          end

          def resolve_capability_policy(model_info)
            model_id = model_info.id.to_s
            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: capabilities_from_api(model_info),
              provider_catalog: {},
              probe: {},
              provider_envelope: { streaming: true },
              provider_config: provider_level_config,
              instance_config: instance_level_config,
              model_config: model_level_config(model_id)
            )
          end

          def capabilities_from_api(model_info)
            Array(model_info.capabilities).each_with_object({}) do |cap, hash|
              sym = cap.to_s.downcase.to_sym
              hash[sym] = true
            end
          end

          def provider_level_config
            raw = CredentialSources.setting(:extensions, :llm, :ollama)
            return {} unless raw.is_a?(Hash)

            raw.reject { |k, _| k.to_sym == :instances }
          end

          def instance_level_config
            extract_config_hash
          end

          def model_level_config(model_id)
            data = extract_config_hash
            models = data[:models]
            return {} unless models.is_a?(Hash)

            models[model_id.to_sym] || models[model_id.to_s] || models[model_id] || {}
          end

          def extract_config_hash
            return config.to_h if config.respond_to?(:to_h) && !config.is_a?(Legion::Extensions::Llm::HashConfig)

            if config.is_a?(Legion::Extensions::Llm::HashConfig)
              config.instance_variable_get(:@data) || {}
            else
              {}
            end
          end

          def offering_usage_type(model_info)
            model_info.embedding? ? :embedding : :inference
          end

          def offering_limits(model_info)
            ctx = model_info.context_length || resolve_context_window(model_info.id)
            ctx ? { context_window: ctx } : {}
          end

          def resolve_context_window(model_id)
            detail = model_detail(model_id)
            return detail[:context_window] if detail.is_a?(Hash) && detail[:context_window]

            infer_context_window(model_id)
          end

          def infer_context_window(model_id)
            name = model_id.to_s.split(':').first
            CONTEXT_WINDOWS.find { |prefix, _| name.start_with?(prefix) }&.last
          end

          def extract_context_window(raw)
            return nil unless raw.is_a?(Hash)

            from_model_info(raw) || from_parameters_string(raw)
          end

          def from_model_info(raw)
            model_info = raw['model_info'] || raw[:model_info]
            return unless model_info.is_a?(Hash)

            num_ctx_from_hash(model_info)&.to_i
          end

          def num_ctx_from_hash(model_info)
            model_info['num_ctx'] || model_info[:num_ctx] ||
              model_info.find { |k, _| k.to_s.end_with?('.context_length') }&.last
          end

          def from_parameters_string(raw)
            params = raw['parameters'] || raw[:parameters]
            return unless params.is_a?(String)

            match = params.match(/num_ctx\s+(\d+)/)
            match[1].to_i if match
          end

          def offering_metadata(model_info)
            {
              context_length: model_info.context_length,
              family: model_info.family,
              size_bytes: model_info.size_bytes
            }.compact
          end

          def ollama_keep_alive
            settings[:keep_alive]
          end

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:)
            model_id = model.respond_to?(:id) ? model.id : model
            log.debug do
              "ollama provider rendering chat payload model=#{model_id} message_count=#{messages.size} " \
                "stream=#{stream} tools=#{tools.size} schema=#{!schema.nil?} thinking=#{thinking ? true : false}"
            end

            {
              model: model_id,
              messages: format_messages(messages),
              stream: stream,
              think: thinking == true,
              keep_alive: ollama_keep_alive,
              format: schema_format(schema),
              options: { temperature: temperature }.compact,
              tools: format_tools(tools),
              tool_choice: tool_choice(tool_prefs)
            }.compact
          end

          def stream_response(connection, payload, additional_headers = {}, &block)
            buffer = +''
            chunks = []

            connection.post(stream_url, payload) do |req|
              req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
              req.options.on_data = ndjson_handler(buffer, chunks, block)
            end

            finalize_stream(chunks)
          end

          def ndjson_handler(buffer, chunks, block)
            proc do |chunk_data, _bytes, env|
              next if env.respond_to?(:status) && env.status && env.status != 200

              buffer << chunk_data.to_s
              drain_ndjson_buffer(buffer, chunks, block)
            end
          end

          def drain_ndjson_buffer(buffer, chunks, block)
            while (idx = buffer.index("\n"))
              line = buffer.slice!(0..idx).strip
              next if line.empty?

              parse_ndjson_line(line, chunks, block)
            end
          end

          def parse_ndjson_line(line, chunks, block)
            parsed = Legion::JSON.parse(line, symbolize_names: false)
            return unless parsed.is_a?(Hash)

            built = build_chunk(parsed)
            chunks << built
            block&.call(built)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :debug, handled: true, operation: 'ollama.stream_parse')
          end

          def finalize_stream(chunks)
            return Legion::Extensions::Llm::Message.new(role: :assistant, content: nil) if chunks.empty?

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: join_stream_content(chunks),
              thinking: join_stream_thinking(chunks),
              tool_calls: merge_stream_tool_calls(chunks),
              model_id: chunks.last.model_id,
              input_tokens: chunks.last.input_tokens,
              output_tokens: chunks.last.output_tokens,
              raw: chunks.last.raw
            )
          end

          def join_stream_content(chunks)
            text = chunks.filter_map { |c| c.content&.to_s }.join
            text.empty? ? nil : text
          end

          def join_stream_thinking(chunks)
            parts = chunks.filter_map { |c| c.thinking&.text }
            Thinking.build(text: parts.empty? ? nil : parts.join)
          end

          def merge_stream_tool_calls(chunks)
            merged = chunks.filter_map(&:tool_calls).reject(&:empty?).reduce({}, :merge)
            merged.empty? ? nil : merged
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

            tool_names = tools.values.filter_map { |tool| Legion::Extensions::Llm::Canonical::ToolSchema.tool_name(tool) }
            log.debug { "ollama provider formatting tools count=#{tools.size} names=#{tool_names.join(',')}" }

            tools.values.map do |tool|
              {
                type: 'function',
                function: {
                  name: Legion::Extensions::Llm::Canonical::ToolSchema.tool_name(tool),
                  description: Legion::Extensions::Llm::Canonical::ToolSchema.tool_description(tool),
                  parameters: Legion::Extensions::Llm::Canonical::ToolSchema.extract(tool)
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
            canonical = translator.parse_response(body)
            to_legacy_message(canonical, body)
          end

          def build_chunk(data)
            canonical_chunk = translator.parse_chunk(data)
            return nil if canonical_chunk.nil?

            to_legacy_chunk(canonical_chunk, data)
          end

          def to_legacy_message(canonical, raw_body)
            usage = canonical.usage
            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: canonical.text,
              model_id: canonical.model,
              thinking: if canonical.thinking
                          Legion::Extensions::Llm::Thinking.build(
                            text: canonical.thinking.content, signature: canonical.thinking.signature
                          )
                        end,
              tool_calls: legacy_tool_calls(canonical.tool_calls),
              input_tokens: usage&.input_tokens,
              output_tokens: usage&.output_tokens,
              raw: raw_body
            )
          end

          def to_legacy_chunk(canonical_chunk, raw_data)
            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: canonical_chunk.text_delta? ? canonical_chunk.delta : nil,
              thinking: if canonical_chunk.thinking_delta?
                          Legion::Extensions::Llm::Thinking.build(
                            text: canonical_chunk.delta
                          )
                        end,
              tool_calls: legacy_streaming_tool_calls(canonical_chunk),
              model_id: raw_data['model'] || raw_data[:model],
              input_tokens: canonical_chunk.usage&.input_tokens ||
                             raw_data['prompt_eval_count'] || raw_data[:prompt_eval_count],
              output_tokens: canonical_chunk.usage&.output_tokens ||
                              raw_data['eval_count'] || raw_data[:eval_count],
              raw: raw_data
            )
          end

          def legacy_tool_calls(canonical_tool_calls)
            return nil if canonical_tool_calls.nil? || canonical_tool_calls.empty?

            canonical_tool_calls.to_h do |tc|
              [
                (tc.name || tc.id).to_s.to_sym,
                Legion::Extensions::Llm::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments || {})
              ]
            end
          end

          def legacy_streaming_tool_calls(canonical_chunk)
            return nil unless canonical_chunk.tool_call_delta?

            tc = canonical_chunk.tool_call
            return nil unless tc

            { (tc.name || tc.id).to_s.to_sym => Legion::Extensions::Llm::ToolCall.new(
              id: tc.id, name: tc.name, arguments: tc.arguments || ''
            ) }
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
            normalized = normalize_ollama_capabilities(api_caps)
            return normalized unless normalized.empty?

            if embedding_model?(name, family)
              [:embedding]
            else
              %i[completion streaming vision]
            end
          end

          def normalize_ollama_capabilities(capabilities)
            Array(capabilities).compact.each_with_object([]) do |capability, result|
              capability_sym = capability.to_s.downcase.strip.to_sym
              next if capability_sym.to_s.empty?

              result << capability_sym
              result << :tools if %i[function_calling functions tool tool_use].include?(capability_sym)
              result << :streaming if %i[chat completion].include?(capability_sym)
            end.uniq
          end

          def extract_capabilities(raw)
            return nil unless raw.is_a?(Hash)

            caps = raw['capabilities'] || raw[:capabilities]
            normalized = normalize_ollama_capabilities(caps)
            normalized unless normalized.empty?
          end

          def embedding_model?(name, family)
            name.to_s.match?(/embed|embedding/i) || family.to_s.match?(/bert|nomic/i)
          end

          def render_embedding_payload(text, model:, dimensions:)
            model_id = model.respond_to?(:id) ? model.id : model
            input_count = text.respond_to?(:size) ? text.size : 1
            log.debug { "ollama provider rendering embedding payload model=#{model_id} input_count=#{input_count}" }

            { model: model_id, input: text, dimensions: dimensions }.compact
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

            vector_count = vectors.respond_to?(:size) ? vectors.size : 0
            log.debug { "ollama provider parsed embedding response model=#{model} vector_count=#{vector_count}" }

            Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model,
                                                   input_tokens: body['prompt_eval_count'].to_i)
          end
        end
      end
    end
  end
end
