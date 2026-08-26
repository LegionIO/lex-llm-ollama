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
            def slug = 'ollama'
            def local? = true
            def default_transport = :http
            def default_tier = :local
            def configuration_requirements = []
            def capabilities = Capabilities
          end

          # Capability predicates for Ollama model offerings.
          # vision?, functions?, and embedding? are not authoritative for every
          # Ollama model; evidence is derived per-model by the discovery
          # runner via /api/tags and /api/show. Unknown returns false here.
          module Capabilities
            module_function

            def chat?(_model) = true
            def streaming?(_model) = true
            def vision?(_model) = false
            def functions?(_model) = false
            def embedding?(_model) = false
          end

          def settings
            Ollama.default_settings
          end

          def translator
            @translator ||= Translator.new(config: config)
          end

          def api_base
            resolve_base_url || normalize_url(settings[:instances][:default][:endpoint])
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
            super
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

          private

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

          def ollama_keep_alive
            settings[:keep_alive]
          end

          # One request-render boundary (08 R1): renders the Ollama /api/chat
          # wire FROM canonical values. The base funnel enforces canonical
          # messages centrally before this runs (08 F2); the provider-spelled
          # options keys (num_predict, ...) are the translator's edge mapping
          # (03 O03a, R4).
          def render_payload(messages, tools:, model:, stream:, schema:, thinking:, params:, tool_prefs:)
            model_id = model.respond_to?(:id) ? model.id : model
            log.debug do
              "ollama provider rendering chat payload model=#{model_id} message_count=#{messages.size} " \
                "stream=#{stream} tools=#{tools.size} schema=#{!schema.nil?} thinking=#{thinking ? true : false}"
            end

            {
              model: model_id,
              messages: format_messages(messages),
              stream: stream,
              think: think_enabled?(thinking),
              keep_alive: ollama_keep_alive,
              format: schema_format(schema),
              options: translator.options_for(params),
              tools: format_tools(tools),
              tool_choice: tool_choice(tool_prefs)
            }.compact
          end

          # Ollama think flag: true only for an enabled Thinking::Config;
          # absent thinking is an explicit false, never a default-on.
          def think_enabled?(thinking)
            thinking ? thinking.enabled? : false
          end

          # NDJSON streaming (Ollama is not SSE): the one streaming contract —
          # yield Canonical::Chunk to the block, end in exactly one done chunk
          # (or an error chunk before the raise), return the accumulated
          # Canonical::Response (05 O5, 08 R2). Chunk assembly is the shared
          # StreamAccumulator (10 U1), not a per-gem join.
          def stream_response(connection, payload, additional_headers = {}, model: nil, &block)
            accumulator = StreamAccumulator.new
            buffer = +''

            begin
              connection.post(stream_url, payload) do |req|
                req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
                req.options.on_data = ndjson_handler(buffer, accumulator, block)
              end
            rescue StandardError => e
              block&.call(Canonical::Chunk.error_chunk(error: e, request_id: nil))
              raise
            end

            accumulator.flush_pending_chunk.each { |chunk| block&.call(chunk) }

            response = accumulator.to_response(model:)
            log.debug { "ollama stream completed text_length=#{response.text.to_s.length}" }
            done = Canonical::Chunk.done(request_id: nil, usage: response.usage, stop_reason: response.stop_reason)
            block&.call(done)
            response
          end

          def ndjson_handler(buffer, accumulator, block)
            proc do |chunk_data, _bytes, env|
              status = env.respond_to?(:status) ? env.status : nil
              next if status.nil?

              if status != 200
                # Non-200 streaming bodies are the ONE error path: the shared
                # streaming failure handler raises the typed error (10 U8) —
                # a non-200 line is never silently skipped.
                handle_failed_response(chunk_data.to_s, buffer, env)
                next
              end

              buffer << chunk_data.to_s
              drain_ndjson_buffer(buffer, accumulator, block)
            end
          end

          def drain_ndjson_buffer(buffer, accumulator, block)
            while (idx = buffer.index("\n"))
              line = buffer.slice!(0..idx).strip
              next if line.empty?

              emit_ndjson_line(line, accumulator, block)
            end
          end

          def emit_ndjson_line(line, accumulator, block)
            parsed = Legion::JSON.parse(line, symbolize_names: false)
            return unless parsed.is_a?(Hash)

            emit_parsed_chunk(parsed, accumulator, block)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'ollama.stream_parse')
          end

          def emit_parsed_chunk(data, accumulator, block)
            result = build_chunk(data)
            return unless result

            Array(result).each do |chunk|
              accumulator.add(chunk).each { |emitted| block&.call(emitted) }
            end
          end

          # One chunk-parse boundary (08 R2): an Ollama NDJSON line is parsed
          # to a Canonical::Chunk by the translator dialect edge; the
          # accumulator owns assembly, this boundary owns the type.
          def build_chunk(data)
            translator.parse_chunk(data)
          end

          def format_messages(messages)
            messages.map do |message|
              content = message.content
              payload = { role: message.role.to_s, content: format_content(content) }
              images = image_payloads(content)
              payload[:images] = images unless images.empty?
              payload[:tool_call_id] = message.tool_call_id if message.role.to_sym == :tool && message.tool_call_id
              payload
            end
          end

          # Canonical content only (08 R2): String | ContentBlock |
          # Array<ContentBlock> | nil — one render code path. Non-text blocks
          # (image) ride in the images array, never in the content string.
          def format_content(content)
            return content.to_s if content.nil? || content.is_a?(::String)

            Array(content).filter_map do |block|
              block.is_a?(Canonical::ContentBlock) && block.text? ? block.text.to_s : nil
            end.join
          end

          # Ollama image wire: the base64 payloads of the canonical :image
          # content blocks (G20a).
          def image_payloads(content)
            return [] unless content.is_a?(::Array)

            content.filter_map do |block|
              block.is_a?(Canonical::ContentBlock) && block.type == :image ? block.data : nil
            end
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

          # One response-parse boundary (08 R2): an Ollama /api/chat body is
          # parsed to a Canonical::Response by the translator dialect edge.
          def parse_completion_response(response)
            translator.parse_response(response.body)
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

          def render_embedding_payload(text, model:, dimensions:)
            model_id = model.respond_to?(:id) ? model.id : model
            input_count = text.respond_to?(:size) ? text.size : 1
            log.debug { "ollama provider rendering embedding payload model=#{model_id} input_count=#{input_count}" }

            { model: model_id, input: text, dimensions: dimensions }.compact
          end

          # 05 §3 documented artifact: { text:, model:, embedding:
          # Array<Float>, usage: Canonical::Usage }.
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
            prompt_eval_count = body['prompt_eval_count']
            usage = prompt_eval_count ? Canonical::Usage.build(input_tokens: prompt_eval_count) : nil

            {
              text: text,
              model: model.respond_to?(:id) ? model.id : model,
              embedding: vectors,
              usage: usage
            }.compact
          end
        end
      end
    end
  end
end
