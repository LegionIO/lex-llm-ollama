# frozen_string_literal: true

require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/responses/thinking_extractor'
require 'legion/json'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Ollama
        # Canonical provider translator for Ollama (/api/chat NDJSON wire format).
        #
        # Implements render_request, parse_response, parse_chunk, and capabilities.
        # Ollama uses NDJSON streaming (not SSE), native tool calling, and the `think`
        # flag for extended thinking support.
        #
        # Ollama quirks (declared in capabilities):
        # - tool_calls_as_text: false — Ollama returns structured tool_calls natively.
        # - forced_tool_choice: false — Ollama does not support forced tool selection.
        # - assistant_prefill: false — Ollama does not support assistant prefill.
        class Translator
          include Legion::Logging::Helper

          # Ollama-specific stop_reason mapping (done_reason field).
          OLLAMA_STOP_REASON_MAP = {
            'stop' => :end_turn,
            'tool_use' => :tool_use,
            'length' => :max_tokens
          }.freeze
          FALLBACK_STOP_REASON = :end_turn

          # G18 parameter mapping: canonical params -> Ollama options keys.
          PARAM_OPTIONS_KEYS = {
            max_tokens: :num_predict,
            temperature: :temperature,
            top_p: :top_p,
            top_k: :top_k,
            stop_sequences: :stop,
            seed: :seed,
            frequency_penalty: :frequency_penalty,
            presence_penalty: :presence_penalty
          }.freeze

          SUPPORTED_PARAMS = %i[
            max_tokens temperature top_p top_k stop_sequences
            seed frequency_penalty presence_penalty
          ].freeze

          def initialize(config: nil)
            @config = config
          end

          # Render a canonical request into Ollama /api/chat wire payload.
          def render_request(request)
            model = request.metadata&.dig(:model) || 'default'
            messages = format_messages(request)
            payload = {
              model: model,
              messages: messages,
              stream: request.stream
            }

            payload[:tools] = format_tools(request.tools) unless request.tools.to_h.empty?
            apply_options(payload, request.params)
            apply_thinking_config(payload, request)
            apply_response_format(payload, request.params)

            log.debug do
              "[llm][ollama-translator] action=render_request model=#{model} stream=#{request.stream} " \
                "message_count=#{messages.size} tools=#{request.tools&.size || 0}"
            end

            payload.compact
          end

          # Parse an Ollama /api/chat completion response into a Canonical::Response.
          def parse_response(wire)
            return canonical_error_response(wire) unless wire.is_a?(Hash)
            return Canonical::Response.from_hash(wire) if canonical_response?(wire)

            message = wire[:message] || wire['message'] || {}
            content = message[:content] || message['content'] || ''
            tool_calls_raw = message[:tool_calls] || message['tool_calls']
            model = wire[:model] || wire['model']
            done_reason = wire[:done_reason] || wire['done_reason']
            done = wire[:done] || wire['done']

            extraction = Responses::ThinkingExtractor.extract(
              content,
              metadata: thinking_metadata(message)
            )

            text = extraction.content || ''
            thinking = build_canonical_thinking(extraction)
            tool_calls = parse_tool_calls(tool_calls_raw)
            stop_reason = map_stop_reason(done_reason, done)

            usage = Canonical::Usage.from_hash({
                                                 input_tokens: wire[:prompt_eval_count] || wire['prompt_eval_count'],
                                                 output_tokens: wire[:eval_count] || wire['eval_count']
                                               })

            Canonical::Response.build(
              text: text.to_s,
              thinking: thinking,
              tool_calls: tool_calls,
              usage: usage,
              stop_reason: stop_reason,
              model: model,
              metadata: {}
            )
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'ollama.translator.parse_response')
            raise
          end

          # Parse a single NDJSON chunk into a Canonical::Chunk or nil.
          def parse_chunk(raw)
            return nil if raw.nil?

            data = normalize_chunk_input(raw)
            return nil if data.nil?

            # Handle canonical-form chunks (from conformance fixtures)
            return handle_canonical_chunk(data) if data['type'] || data[:type]

            parse_ollama_chunk(data)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'ollama.translator.parse_chunk')
            raise
          end

          # Declared capabilities for the Ollama provider.
          def capabilities
            {
              provider: 'ollama',
              streaming: true,
              tool_calls: true,
              thinking: true,
              vision: true,
              embeddings: true,
              tool_calls_as_text: false,
              forced_tool_choice: false,
              assistant_prefill: false
            }.freeze
          end

          private

          attr_reader :config

          # -- Message formatting --

          def format_messages(request)
            messages = format_request_messages(request.messages)

            if request.system.to_s.strip.empty?
              messages
            else
              [{ role: 'system', content: request.system.strip }] + messages
            end
          end

          def format_request_messages(messages)
            return [] if messages.nil? || messages.empty?

            messages.map { |msg| format_message(msg) }
          end

          def format_message(msg)
            role = msg.role.to_s
            content = format_message_content(msg)
            result = { role: role, content: content }

            images = extract_images(msg.content)
            result[:images] = images unless images.empty?

            result[:tool_call_id] = msg.tool_call_id if msg.tool_call_id
            result.compact
          end

          def format_message_content(msg)
            content = msg.content
            return content if content.is_a?(String)

            case content
            when Array
              extract_text_from_blocks(content)
            when Canonical::ContentBlock
              content.text? ? content.text.to_s : content.to_s
            else
              content.to_s
            end
          end

          def extract_text_from_blocks(blocks)
            parts = blocks.filter_map do |block|
              case block
              when Canonical::ContentBlock
                format_content_block_text(block)
              when Hash
                block_hash = block.transform_keys(&:to_sym)
                block_hash[:text]&.to_s
              else
                block.to_s
              end
            end
            parts.join
          end

          def format_content_block_text(block)
            case block.type
            when :text, :thinking
              block.text.to_s
            when :tool_use
              Legion::JSON.dump({ name: block.name, arguments: block.input || {} })
            when :tool_result
              block.text.to_s
            end
          end

          def extract_images(content)
            return [] unless content.is_a?(Array)

            content.filter_map do |block|
              next unless block.is_a?(Canonical::ContentBlock) && block.type == :image

              block.data
            end
          end

          # -- Tool formatting --

          def format_tools(tools)
            return nil if tools.to_h.empty?

            tools.to_h.values.map do |tool|
              tool_hash = if tool.is_a?(Canonical::ToolDefinition)
                            { name: tool.name, description: tool.description, parameters: tool.parameters }
                          elsif tool.is_a?(Hash)
                            tool.transform_keys(&:to_sym)
                          else
                            tool
                          end

              name = tool_hash[:name] || tool_hash['name']
              description = (tool_hash[:description] || tool_hash['description'] || '').to_s
              parameters = tool_hash[:parameters] || tool_hash[:input_schema] ||
                           { type: 'object', properties: {} }
              parameters = parameters.to_h if parameters.respond_to?(:to_h) && !parameters.is_a?(Hash)
              parameters = { type: 'object', properties: {} } unless parameters.is_a?(Hash)

              {
                type: 'function',
                function: {
                  name: name.to_s,
                  description: description,
                  parameters: parameters
                }
              }
            end
          end

          # -- Parameter mapping (G18) --

          def apply_options(payload, params)
            return unless params.is_a?(Canonical::Params)

            options = {}
            SUPPORTED_PARAMS.each do |param_key|
              value = params.public_send(param_key)
              next if value.nil?

              wire_key = PARAM_OPTIONS_KEYS[param_key]
              options[wire_key] = case param_key
                                  when :stop_sequences
                                    Array(value)
                                  else
                                    value
                                  end
            end

            payload[:options] = options unless options.empty?

            return unless params.max_thinking_tokens

            log.debug do
              '[llm][ollama-translator] action=drop_unsupported_param param=max_thinking_tokens ' \
                "value=#{params.max_thinking_tokens} reason=ollama_not_supported"
            end
          end

          # -- Thinking configuration --

          def apply_thinking_config(payload, request)
            return unless enable_thinking?(request)

            payload[:think] = true
          end

          def enable_thinking?(request)
            return true if request.thinking.is_a?(Canonical::Thinking::Config) && request.thinking.enabled?
            return true if request.thinking.is_a?(Hash) && (request.thinking[:enabled] != false)

            false
          end

          # -- Response format --

          def apply_response_format(payload, params)
            return unless params.is_a?(Canonical::Params) && params.response_format

            format_value = params.response_format
            payload[:format] = if format_value.is_a?(Hash)
                                 schema = format_value[:schema] || format_value['schema'] ||
                                          format_value[:json_schema] || format_value['json_schema']
                                 schema || format_value
                               else
                                 format_value
                               end
          end

          # -- Response parsing --

          def canonical_response?(wire)
            wire.key?(:text) || wire.key?('text') || wire.key?(:stop_reason) || wire.key?('stop_reason')
          end

          def canonical_error_response(wire)
            body = wire.is_a?(Hash) ? wire : {}
            error_info = body['error'] || body[:error] ||
                         { type: 'parse_error', message: 'Failed to parse response' }

            Canonical::Response.build(
              text: '',
              tool_calls: [],
              usage: Canonical::Usage.from_hash(body['usage'] || body[:usage] || {}),
              stop_reason: :error,
              model: body['model'] || body[:model],
              metadata: { error: error_info }
            )
          end

          def thinking_metadata(message)
            thinking = message[:thinking] || message['thinking']
            return {} unless thinking

            { thinking: thinking }
          end

          def build_canonical_thinking(extraction)
            return nil unless extraction.thinking || extraction.signature

            Canonical::Thinking.new(
              content: extraction.thinking,
              signature: extraction.signature
            )
          end

          def parse_tool_calls(tool_calls_raw)
            return [] unless tool_calls_raw.is_a?(Array) && !tool_calls_raw.empty?

            tool_calls_raw.filter_map do |call|
              call = call.transform_keys(&:to_sym) if call.is_a?(Hash)
              function = call[:function] || call['function'] || {}
              function = function.transform_keys(&:to_sym) if function.is_a?(Hash)

              name = function[:name] || function['name']
              id = call[:id] || call['id'] || name
              args = parse_tool_arguments(function[:arguments] || function['arguments'])

              Canonical::ToolCall.build(
                id: id.to_s,
                name: name.to_s,
                arguments: args,
                source: :client
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'ollama.translator.parse_tool_call')
              nil
            end
          end

          def parse_tool_arguments(arguments)
            return {} if arguments.nil? || arguments == ''
            return arguments if arguments.is_a?(Hash)

            Legion::JSON.load(arguments)
          rescue Legion::JSON::ParseError
            {}
          end

          def map_stop_reason(done_reason, done = nil)
            if done_reason
              OLLAMA_STOP_REASON_MAP.fetch(done_reason.to_s, FALLBACK_STOP_REASON)
            elsif done
              FALLBACK_STOP_REASON
            end
          end

          # -- Chunk parsing --

          def normalize_chunk_input(raw)
            return nil if raw.is_a?(String) && raw.strip.empty?

            raw.is_a?(Hash) ? raw : parse_json_safely(raw)
          end

          def handle_canonical_chunk(data)
            normalized = data.is_a?(Hash) && data.keys.first.is_a?(Symbol) ? data : data.transform_keys(&:to_sym)
            Canonical::Chunk.from_hash(normalized)
          rescue StandardError => e
            log.debug { "[llm][ollama-translator] action=canonical_chunk_parse_error error=#{e.message}" }
            nil
          end

          def parse_ollama_chunk(data)
            message = data[:message] || data['message'] || {}
            done = data[:done] || data['done']
            done_reason = data[:done_reason] || data['done_reason']
            request_id = data[:request_id] || data['request_id'] || data[:id] || data['id']

            # Done chunk
            return build_done_chunk(data, done_reason, request_id) if done

            # Tool call delta
            tool_calls = message[:tool_calls] || message['tool_calls']
            return build_tool_call_chunk(tool_calls, request_id) unless Array(tool_calls).empty?

            # Thinking delta
            thinking_content = message[:thinking] || message['thinking']
            unless thinking_content.to_s.empty?
              return Canonical::Chunk.thinking_delta(
                delta: thinking_content.to_s,
                request_id: request_id
              )
            end

            # Text delta
            content = message[:content] || message['content']
            unless content.to_s.empty?
              return Canonical::Chunk.text_delta(
                delta: content.to_s,
                request_id: request_id
              )
            end

            nil
          end

          def build_done_chunk(data, done_reason, request_id)
            usage = Canonical::Usage.from_hash({
                                                 input_tokens: data[:prompt_eval_count] || data['prompt_eval_count'],
                                                 output_tokens: data[:eval_count] || data['eval_count']
                                               })

            Canonical::Chunk.done(
              request_id: request_id,
              usage: usage,
              stop_reason: map_stop_reason(done_reason, true)
            )
          end

          def build_tool_call_chunk(tool_calls, request_id)
            first_call = tool_calls.first
            first_call = first_call.transform_keys(&:to_sym) if first_call.is_a?(Hash)
            function = first_call[:function] || first_call['function'] || {}
            function = function.transform_keys(&:to_sym) if function.is_a?(Hash)

            tc = Canonical::ToolCall.build(
              id: (first_call[:id] || first_call['id'] || function[:name] || 'synthesized').to_s,
              name: (function[:name] || function['name']).to_s,
              arguments: parse_tool_arguments(function[:arguments] || function['arguments']),
              source: :client
            )

            Canonical::Chunk.tool_call_delta(
              tool_call: tc,
              request_id: request_id
            )
          end

          # -- JSON helpers --

          def parse_json_safely(raw)
            return nil unless raw.is_a?(String)

            Legion::JSON.load(raw)
          rescue Legion::JSON::ParseError => e
            log.debug { "[llm][ollama-translator] action=json_parse_error error=#{e.message}" }
            nil
          end
        end
      end
    end
  end
end
