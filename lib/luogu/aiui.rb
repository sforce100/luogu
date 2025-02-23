# frozen_string_literal: true

module Luogu
  class AIUI < Base
    setting :id, default: Application.config.aiui.id
    setting :key, default: Application.config.aiui.key
    setting :request_url, default: Application.config.aiui.host
    setting :parse, default: ->(response) { response.parse.dig("data", 0, "intent", "answer") }

    class << self
      def request(text: nil, uid: SecureRandom.hex(16), options: {})
        response = HTTP.post(config.request_url, json: {
          appid: config.id,
          appkey: config.key,
          uid: uid,
          text: text
        }.merge(options))
        if response.code == 200
          config.parse.call(response)
        else
          raise RequestError, response.body.to_s
        end
      end
    end
  end
end
