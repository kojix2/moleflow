require "grpc"
require "../../lib/minknow/src/generated/minknow_api/data.pb"
require "../../lib/minknow/src/generated/minknow_api/manager.pb"
require "../../lib/minknow/src/generated/minknow_api/instance.pb"
require "../../lib/minknow/src/generated/minknow_api/analysis_configuration.pb"
require "../../lib/minknow/src/generated/minknow_api/acquisition.pb"
require "../../lib/minknow/src/generated/minknow_api/protocol.pb"
require "./config"

module Moleflow
  macro pb(type, **fields)
    {{ type }}.new.tap do |message|
      {% for key, value in fields %}
        message.{{ key.id }} = {{ value }}
      {% end %}
    end
  end

  alias D = MinknowApi::Data
end
