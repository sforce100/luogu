# frozen_string_literal: true

module Luogu
  class AgentRunner < Base
    setting :model, default: Application.config.run_agent_model
    setting :global_agent, default: Application.config.run_agent_global

    setting :templates do
      setting :system, default: PromptTemplate.load_template('agent_system.md.erb')
      setting :user, default: PromptTemplate.load_template('agent_input.md.erb')
      setting :tool, default: PromptTemplate.load_template('agent_tool_input.md.erb')
    end

    setting :run_agent_retries, default: Application.config.run_agent_retries

    setting :provider do
      setting :parameter_model, default: ->() {
        OpenAI::ChatRequestParams.new(
          model: 'gpt-3.5-turbo',
          stop: %W[\nObservation: \n\tObservation:],
          temperature: 0
        )
      }
      setting :request, default: ->(params) { OpenAI.chat(params: params) }
      setting :parse, default: ->(response) { OpenAI.chat_response_handle(response) }
      setting :find_final_answer, default: ->(content) { OpenAI.find_final_answer(content) }
      setting :history_limit, default: Application.config.openai.history_limit
    end

    attr_reader :request_params, :agents, :histories
    attr_accessor :is_tool_response, :last_user_input, :global_params
    attr_accessor :openai_client, :final_answer_params
    def initialize(options={})
      @request_params = provider.parameter_model.call
      @request_params.stream = options[:stream].nil? ? false : options[:stream]
      @histories = HistoryQueue.new provider.history_limit
      @last_user_input = ''
      @agents = []
      @tools_response = []
      @is_tool_response = false
    end

    def provider
      config.provider
    end

    def templates
      config.templates
    end

    def register(agent)
      raise AssertionError.new('agent must inherit from Luogu::Agent') unless agent < Agent
      @agents << agent
      self
    end

    def run(text)
      @is_tool_response = false
      @last_user_input = text
      messages = create_messages(
        [{role: "user", content: templates.user.result(binding)}]
      )
      request(messages)
    end
    alias_method :chat, :run

    def create_messages(messages)
      [
        { role: "system", content: templates.system.result(binding) }
      ] + @histories.to_a + messages
    end

    def request(messages, run_agent_retries: 0)
      logger.debug "request chat: #{messages}"
      @request_params.messages = messages
      response = openai_client.present? ? openai_client.chat(params: @request_params.to_h) : provider.request.call(@request_params.to_h)
      unless response.code == 200
        logger.error response.body.to_s
        raise RequestError
      end
      content = provider.parse.call(response)
      logger.debug content
      if (answer = self.find_and_save_final_answer(content))
        logger.info "final answer: #{answer}"
        answer
      elsif content.is_a?(Array)
        run_agents(content, messages, run_agent_retries: run_agent_retries)
      else
        logger.info "unformat answer: #{content}"
      end
      rescue JSON::ParserError => e
        response_content = OpenAI.get_content(response)
        logger.info "agent format json error: #{response_content}"
        @final_answer_params['action_input'] = response_content
    end

    def find_and_save_final_answer(content)
      if (@final_answer_params = provider.find_final_answer.call(content))
        @histories.enqueue({role: "user", content: @last_user_input})
        @histories.enqueue({role: "assistant", content: @final_answer_params['action_input']})
        @final_answer_params['action_input']
      else
        nil
      end
    end

    def run_agents(agents, _messages_, run_agent_retries: 0)
      return if run_agent_retries > config.run_agent_retries
      run_agent_retries += 1
      if (answer = find_and_save_final_answer(agents))
        logger.info "final answer: #{answer}"
        return
      end
      @tools_response = []
      response = nil
      agents.each do |agent|
        agent_class = Module.const_get(agent['action'])
        logger.info "#{run_agent_retries} running #{agent_class} input: #{agent['action_input']}"
        response = agent_class.new.call(self, agent['action_input'])
        @tools_response << {name: agent['action'], response: response}
      end
      if config.model == AgentModel::SIMPLE
        simple_runner(response)
      else
        messages = _messages_ + [
          { role: "assistant", content: agents.to_json },
          { role: "user", content: templates.tool.result(binding) }
        ]
        request messages, run_agent_retries: run_agent_retries
      end
    end

    def simple_runner(response)
      if response.nil? && !global_agent.nil?
        response = global_agent.new.call(self, @last_user_input)
      end
      
      logger.info "simple final answer: #{response}"
      return find_and_save_final_answer({'action' => 'Final Answer', 'action_input' => response})
    end
  end
end
