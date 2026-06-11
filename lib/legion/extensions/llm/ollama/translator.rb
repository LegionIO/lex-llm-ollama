# frozen_string_literal: true

require 'legion/extensions/llm/canonical'
require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module Ollama
        class Translator
          include Legion::Logging::Helper

          OPEN_TAG =
            CLOSE_TAG =

              SUPPORTED_PARAMS = [
                [:max_tokens, :num_predict, 'max_tokens->num_predict'],
                [:temperature, :temperature, 'temperature'],
                [:top_p, :top_p, 'top_p'],
                [:top_k, :top_k, 'top_k'],
                [:seed, :seed, 'seed']
              ].freeze

          UNSUPPORTED_PARAMS = %i[max_thinking_tokens frequency_penalty presence_penalty].freeze

          class << self
            attr_writer :keep_alive, :strict_params

            def keep_alive
              @keep_alive || Ollama.default_settings.dig(:instances, :default, :keep_alive) || '5m'
            end

            def strict_params
              @strict_params.nil? ? false : @strict_params
            end
          end

          def render_request(request)
            log.debug('[ollama][translator] rendering canonical request to Ollama wire format')

            model_id = resolve_model(request)
            messages = render_messages(request.messages)
            options = render_options(request)
            tools = render_tools(request.tools)
            tool_choice = render_tool_choice(request.tool_choice)
            format_value = render_response_format(request.params)
            think_flag = request.thinking&.enabled? || (request.params&.max_thinking_tokens && true)

            payload = {
              model: model_id,
              messages: messages,
              stream: request.stream,
              think: think_flag,
              keep_alive: self.class.keep_alive,
              format: format_value,
              options: options,
              tools: tools,
              tool_choice: tool_choice
            }.compact

            messages.unshift({ role: 'system', content: request.system }) if request.system
            payload
          end

          def parse_response(wire)
            wire_h = symbolize_hash(wire)

            return Canonical::Response.from_hash(wire_h) if wire_h.key?(:text) || wire_h.key?(:stop_reason)

            model = wire_h[:model]
            message_data = wire_h[:message] || {}
            usage = parse_usage_from_hash(wire_h)
            content = raw_access(message_data, 'content') || ''
            tool_calls = parse_tool_calls(message_data)
            thinking_meta = raw_access(message_data, 'thinking')
            extracted = extract_thinking_from_content(content.to_s)
            thinking_content = thinking_meta || extracted[:thinking]
            thinking = canonical_thinking(thinking_content)
            text = extracted[:content] || ''
            stop_reason = parse_stop_reason(wire_h)

            Canonical::Response.build(
              text: text,
              thinking: thinking,
              tool_calls: tool_calls,
              usage: usage,
              stop_reason: stop_reason,
              model: model.to_s,
              routing: {},
              metadata: wire_h[:metadata] || {}
            )
          end

          def parse_chunk(raw)
            return nil if raw.nil? || (raw.is_a?(String) && raw.empty?)

            chunk = raw.is_a?(Hash) ? raw : {}

            if chunk.key?('type') && chunk.key?('request_id')
              chunk_sym = symbolize_hash(chunk)
              return Canonical::Chunk.from_hash(chunk_sym)
            end
            return Canonical::Chunk.from_hash(chunk) if chunk.key?(:type) && chunk.key?(:request_id)

            done = done?(chunk)
            return final_chunk(chunk) if done

            message_data = chunk[:message] || chunk['message'] || {}
            index = chunk[:index] || chunk['index'] || 0
            request_id = chunk[:request_id] || chunk['request_id']
            content = raw_access(message_data, 'content')

            if content && !content.empty?
              extracted = extract_thinking_from_content(content)
              return Canonical::Chunk.text_delta(delta: extracted[:content], request_id: request_id, index: index)
            end

            thinking_text = raw_access(message_data, 'thinking')
            if thinking_text && !thinking_text.empty?
              return Canonical::Chunk.thinking_delta(
                delta: thinking_text,
                request_id: request_id,
                index: index,
                signature: nil
              )
            end

            tool_call_delta(chunk, request_id, index)
          end

          def capabilities
            {
              provider: 'ollama',
              streaming: true,
              thinking: true,
              tool_calls: true,
              api_chat_field_mapping: true,
              thinking_via_think_flag: true,
              thinking_dual_source: true,
              options_subhash: true,
              response_format_json_schema: true,
              thinking_tags: OPEN_TAG,
              param_mappings: {
                max_tokens: 'num_predict',
                temperature: 'temperature',
                top_p: 'top_p',
                top_k: 'top_k',
                stop_sequences: 'stop',
                seed: 'seed',
                response_format: 'format'
              }.freeze
            }.freeze
          end

          private

          def resolve_model(request)
            id = request.metadata&.dig(:resolved_model)&.to_s
            return id if id

            id = request.metadata&.dig(:model)&.to_s
            return id if id

            default_settings[:default_model]&.to_s || 'qwen3.5:latest'
          end

          def render_messages(messages)
            return [] unless messages

            messages.map do |msg|
              { role: msg.role.to_s, content: render_content(msg) }.tap do |payload|
                payload[:tool_call_id] = msg.tool_call_id if msg.tool_call_id
              end
            end
          end

          def render_content(message)
            case message
            when Canonical::Message then message_text(message)
            else message.respond_to?(:text) ? message.text.to_s : message.to_s
            end
          end

          def message_text(message)
            case message.content
            when String then message.content
            when Array then text_from_array(message.content)
            else message.content.to_s
            end
          end

          def text_from_array(arry)
            arry.filter_map do |block|
              next block.text if block.is_a?(Canonical::ContentBlock) && block.text?
              next unless block.is_a?(Hash)

              type = block[:type] || block['type']
              block[:text] || block['text'] if %w[text tool_result].include?(type)
            end.join
          end

          def render_params_for_options(params)
            return {} unless params.is_a?(Canonical::Params)

            mapped = {}
            supported = []
            dropped = []

            SUPPORTED_PARAMS.each do |param_sym, mapped_key, label|
              val = params.public_send(param_sym)
              next unless val

              mapped[mapped_key] = val
              supported << label
            end

            stop_seqs = params.stop_sequences
            if stop_seqs
              mapped[:stop] = Array(stop_seqs)
              supported << 'stop_sequences->stop'
            end

            UNSUPPORTED_PARAMS.each do |param_sym|
              val = params.public_send(param_sym)
              next unless val

              dropped << param_sym.to_s
              handle_dropped_param(param_sym.to_s)
            end

            log.debug("[ollama][translator] params mapped: #{supported.join(', ')}") if supported.any?
            log.debug("[ollama][translator] params dropped (unsupported): #{dropped.join(', ')}") if dropped.any?

            mapped
          end

          def render_options(request)
            return {} unless request.params

            render_params_for_options(request.params)
          end

          def render_tools(tools)
            return nil unless tools && !tools.empty?

            tools.values.filter_map { |t| t.respond_to?(:name) ? t.name : nil }
            log.debug('[ollama][translator] formatting tools count=#{tools.size} names=#{names.join(', ')}))
            tools.values.map { |tool| tool_wire(tool) }
          end

          def tool_wire(tool)
            {
              type: 'function',
              function: {
                name: tool_name(tool),
                description: tool_desc(tool),
                parameters: tool_params(tool)
              }
            }
          end

          def tool_params(tool)
            if tool.respond_to?(:parameters) && tool.parameters then tool.parameters
            elsif tool[:parameters] then tool[:parameters]
            elsif tool['parameters'] then tool['parameters']
            elsif tool[:input_schema] then tool[:input_schema]
            elsif tool['input_schema'] then tool['input_schema']
            else { 'type' => 'object', 'properties' => {} }
            end
          end

          def tool_name(tool)
            tool.respond_to?(:name) ? tool.name : tool[:name] || tool['name']
          end

          def tool_desc(tool)
            tool.respond_to?(:description) ? tool.description : (tool[:description] || tool['description'] || '')
          end

          def render_tool_choice(tool_choice)
            return nil unless tool_choice

            case tool_choice
            when Symbol then tool_choice.to_s
            when Hash then tool_choice[:choice] || tool_choice['choice']
            when String then tool_choice
            end
          end

          def render_response_format(param)
            return nil unless param.is_a?(Canonical::Params) && param.response_format
            return nil unless param.response_format.is_a?(Hash)

            rf_type = param.response_format[:type] || param.response_format['type']
            return nil unless %w[json json_object].include?(rf_type)

            param.response_format[:schema] || param.response_format['schema'] || { 'type' => 'object' }
          end

          def extract_thinking_from_content(content)
            return { content: content, thinking: nil } unless content&.include?(OPEN_TAG)

            parts = content.split(OPEN_TAG, 2)
            pre_tag = parts[0]
            if content.include?(CLOSE_TAG)
              rest = parts[1] || ''
              after = rest.split(CLOSE_TAG, 2)
              { content: pre_tag + (after[1] || ''), thinking: after[0] }
            else
              { content: parts[0], thinking: parts[1] }
            end
          end

          def parse_tool_calls(message_data)
            raw = raw_access(message_data, 'tool_calls')
            return [] unless raw && !raw.empty?

            raw.filter_map do |call|
              func = raw_access(call, 'function') || {}
              name = raw_access(func, 'name')
              next unless name

              args_raw = raw_access(func, 'arguments') || {}
              args = args_raw.is_a?(Hash) ? args_raw : parse_json_safely(args_raw.to_s) || {}
              Canonical::ToolCall.build(
                id: raw_access(call, 'id') || name,
                name: name,
                arguments: args,
                source: nil
              )
            end
          end

          def parse_usage_from_hash(raw)
            data = symbolize_hash(raw)
            usage_hash = {
              input_tokens: data[:prompt_eval_count],
              output_tokens: data[:eval_count],
              cache_read_tokens: data[:load_eval_count]
            }.compact
            usage_hash.empty? ? nil : Canonical::Usage.new(**usage_hash)
          end

          def parse_stop_reason(wire)
            data = symbolize_hash(wire)
            explicit = data[:stop_reason]
            return explicit.to_sym if explicit && Canonical::Response::STOP_REASONS.include?(explicit.to_sym)

            message_data = data[:message] || {}
            tool_calls = raw_access(message_data, 'tool_calls')
            return :tool_use if tool_calls && !tool_calls.empty?

            :end_turn
          end

          def parse_json_safely(raw)
            return {} unless raw.is_a?(String) && !raw.empty?

            Legion::JSON.load(raw)
          rescue Legion::JSON::ParseError
            log.debug("[ollama][translator] arguments not parseable as JSON: #{e.message}")
            {}
          end

          def symbolize_hash(obj)
            return obj unless obj.is_a?(Hash)

            obj.transform_keys(&:to_sym).transform_values do |v|
              if v.is_a?(Hash) then symbolize_hash(v)
              elsif v.is_a?(Array) then v.map { |item| item.is_a?(Hash) ? symbolize_hash(item) : item }
              else v
              end
            end
          end

          def handle_dropped_param(_param_name)
            return unless self.class.strict_params

            raise ArgumentError, 'Ollama does not support parameter: {param_name}'
          end

          def raw_access(hash, key)
            return nil unless hash.is_a?(Hash)

            hash[key] || hash[key.to_s]
          end

          def default_settings
            Legion::Extensions::Llm::Ollama.default_settings.dig(:instances, :default) || {}
          end

          def canonical_thinking(content)
            return nil unless content

            Canonical::Thinking.build(content: content.presence, signature: nil)
          end

          def done?(chunk)
            raw_access(chunk, 'done') == true || chunk[:done] == true
          end

          def final_chunk(chunk)
            usage = parse_usage_from_hash(chunk)
            stop_reason = parse_stop_reason(chunk)
            request_id = chunk[:request_id] || chunk['request_id']
            Canonical::Chunk.done(request_id: request_id, usage: usage, stop_reason: stop_reason)
          end

          def tool_call_delta(chunk, request_id, index)
            message_data = chunk[:message] || chunk['message'] || {}
            raw_tool_calls = raw_access(message_data, 'tool_calls')
            return nil unless raw_tool_calls && !raw_tool_calls.empty?

            tc_raw = raw_tool_calls.first
            func = raw_access(tc_raw, 'function') || {}
            name = raw_access(func, 'name')
            tc_id = raw_access(tc_raw, 'id') || name
            args_raw = raw_access(func, 'arguments') || {}
            args = args_raw.is_a?(Hash) ? args_raw : parse_json_safely(args_raw.to_s) || {}

            canonical_tc = Canonical::ToolCall.build(id: tc_id, name: name, arguments: args)
            Canonical::Chunk.tool_call_delta(tool_call: canonical_tc, request_id: request_id, index: index)
          end
        end
      end
    end
  end
end
