# frozen_string_literal: true

module Luogu
  module Application
    extend Dry::Configurable

    setting :openai do
      setting :access_token, default: ENV.fetch('OPENAI_ACCESS_TOKEN')
      setting :retries, default: ENV.fetch('OPENAI_REQUEST_RETRIES', 3).to_i
      setting :host, default: ENV.fetch('OPENAI_HOST', 'https://api.openai.com')
      setting :history_limit, default: ENV.fetch('OPENAI_LIMIT_HISTORY', '6').to_i * 2
      setting :temperature, default: ENV.fetch('OPENAI_TEMPERATURE', 1).to_i
    end

    setting :aiui do
      setting :id, default: ENV.fetch('AIUI_APP_ID')
      setting :key, default: ENV.fetch('AIUI_APP_KEY')
      setting :host, default: ENV.fetch('AIUI_APP_HOST', 'http://api.iflyos.cn/external/ls_log/aiui_request')
    end

    setting :run_agent_retries, default: ENV.fetch('RUN_AGENT_RETRIES', 5).to_i
    setting :run_agent_model, default: AgentModel::AGENT
    setting :run_agent_global, default: nil

    setting :logger, reader: true,
            default: ENV.fetch('LOG_LEVEL', Logger::INFO),
            constructor: proc { |value|
              logger = Logger.new(STDOUT)
              logger.level = value
              logger
            }
  end
end
