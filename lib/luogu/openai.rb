# frozen_string_literal: true

module Luogu::OpenAI
  class ChatRequestParams < Struct.new(:model, :messages, :temperature,
                                     :top_p, :n, :stream, :stop,
                                     :max_tokens, :presence_penalty,
                                     :frequency_penalty, :logit_bias, :user)
    def to_h
      super.reject { |_, v| v.nil? }
    end

    alias to_hash to_h
  end

  def chat(parameters: nil, params: nil, retries: nil)
    params ||= parameters
    retries_left = retries || Luogu::Application.config.openai.retries
    begin
      client.post('/v1/chat/completions', json: params)
    rescue HTTP::Error => e
      if retries_left > 0
        puts "retrying ..."
        retries_left -= 1
        sleep(1)
        retry
      else
        puts "Connection error #{e}"
        return nil
      end
    end
  end

  def client
    @client ||= HTTP.auth("Bearer #{Luogu::Application.config.openai.access_token}")
                    .persistent Luogu::Application.config.openai.host
  end

  def parse_json(markdown)
    json_regex = /```json(.+?)```/im
    json_blocks = markdown.scan(json_regex)
    result_json = nil
    json_blocks.each do |json_block|
      json_string = json_block[0]
      result_json = JSON.parse(json_string)
    end

    if result_json.nil?
      JSON.parse markdown
    else
      result_json
    end
    rescue JSON::ParserError => e
      result_json = fix_parse_json(markdown)
      if result_json.nil? || result_json.none?
        raise e
      else
        return result_json
      end
  end

  def fix_parse_json(str)
    puts "fix_parse_json: #{str}"
    action_params = {}
    regx = /"([^"]+)"\s*:\s*("[^"]+"|\d+)/
    str.scan(regx).each do |regx_val|
      key = regx_val[0].gsub("\"", "")
      value = regx_val[1].gsub("\"", "")
      action_params[key] = value
    end
    action_params
  end

  def chat_response_handle(response)
    parse_json get_content(response)
  end

  def get_content(response)
    if response.body.instance_eval("@streaming")
      response.body.to_s
    else
      response.parse.dig("choices", 0, "message", "content")
    end
  end

  def find_final_answer(content)
    if content.is_a?(Hash) && content['action'] == 'Final Answer'
      content
    elsif content.is_a?(Array)
      result = content.find { |element| element["action"] == "Final Answer" }
      if result
        result
      else
        nil
      end
    else
      nil
    end
  end

  class StreamRequest
    attr_accessor :client

    def initialize client
      @client = client
    end

    def chat(parameters: nil, params: nil, retries: nil)
      params ||= parameters
      retries_left = retries || Luogu::Application.config.openai.retries
      begin
        resp = client.post('/v1/chat/completions', json: params)
        plugins_exec(resp)
        raise HTTP::Error unless resp.code == 200
        return resp
      rescue HTTP::Error => e
        if retries_left > 0
          puts "retrying ..."
          retries_left -= 1
          sleep(1)
          retry
        else
          puts "Connection error #{e}"
          return nil
        end
      end
    end

    def add_plugin(&block)
      @plugins = [] if @plugins.nil?
      if block.present?
        @plugins << block
      end
    end

    def plugins_exec(resp)
      return if @plugins.nil?
      response_body = ""
      tmp_response_chunk = ""
      while (chunk = resp.readpartial)
        tmp_response_chunk += chunk
        parse_result = parse_chunk(tmp_response_chunk)
        events = parse_result[0]
        tmp_response_chunk = parse_result[1]
        events.each do |resp_data|
          resp_type = 'receive'
          delta = ''
          if resp_data.match?(/^\[DONE\]/)
            resp_type = 'done'
          else
            data = JSON.parse(resp_data)
            delta = data.dig('choices', 0, 'delta', 'content') || ''
            response_body += delta
          end
          @plugins.each do |plugin|
            plugin.call(resp_type, delta)
          end
        end
      end
      resp.body.send(:eval, "@contents = response_body")
    end

    def parse_chunk(tmp_response_chunk)
      return [[], tmp_response_chunk] unless tmp_response_chunk.end_with?("\n\n")

      parse_data = tmp_response_chunk.split("\n\n")
      events = parse_data.map { |t| t.gsub(/^data: /, '') }
      [events, '']
    end
  end

  class Messages
    def initialize
      @messages = []
      @system = {}
    end

    def system(text: nil, file: nil)
      data = text || File.read(file)
      @system = {role: "system", content: data}
      self
    end

    def user(text: nil, file: nil)
      data = text || File.read(file)
      @messages << {role: "user", content: data}
      self
    end

    def assistant(text: nil, file: nil)
      data = text || File.read(file)
      @messages << {role: "assistant", content: data}
      self
    end

    def to_a
      @messages.unshift @system
    end

    class << self
      def create
        self.new
      end
    end

  end

  module_function :chat, :client, :parse_json, :chat_response_handle, :find_final_answer, :get_content, :fix_parse_json
end
