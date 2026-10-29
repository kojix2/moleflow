require "./api"

module Moleflow
  class Application
    def initialize(@config : Config, @sources : Array(Source), @model : Model)
    end

    def simulate : Nil
      config, sources, model = @config, @sources, @model
      output = Output.new(config)
      pool = Pool.new(config, sources, model)
      begin
        step = Math.max(1_i64, config.chunk_ms.to_i64 * config.sample_rate // 1000)
        finish = (config.duration_seconds * config.sample_rate).to_i64
        at = 0_i64
        loop do
          output.consume(pool.tick(at))
          break if at >= finish
          at += Math.min(step, finish - at)
        end
      ensure
        begin
          output.consume(pool.close)
        ensure
          output.close
        end
      end
      puts({reads: output.completed, samples: output.samples}.to_json)
    end

    def serve : Nil
      config, sources, model = @config, @sources, @model
      manager = GRPC::Server.new
      position = GRPC::Server.new
      if cert = config.tls_cert
        manager.use_tls(cert: cert, key: (config.tls_key || raise "TLS key missing"))
        position.use_tls(cert: cert, key: (config.tls_key || raise "TLS key missing"))
      end
      manager.handle(Api.new("manager", config, sources, model))
      apis = [] of Api
      ["data", "device", "instance", "analysis_configuration", "acquisition", "protocol", "log"].each do |kind|
        api = Api.new(kind, config, sources, model)
        apis << api
        position.handle(api)
      end
      manager.bind("#{config.host}:#{config.manager_port}")
      position.bind("#{config.host}:#{config.position_port}")
      stop = Channel(Nil).new(1)
      [Signal::INT, Signal::TERM].each { |sig| sig.trap { stop.send(nil) } }
      manager.start
      position.start
      STDERR.puts "moleflow listening: manager=#{config.manager_port} position=#{config.position_port}; run starts with live-read setup"
      stop.receive
      position.stop
      manager.stop
      deadline = Time.instant + 10.seconds
      while apis.any?(&.busy) && Time.instant < deadline
        sleep 10.milliseconds
      end
      raise "shutdown timed out; output may be incomplete" if apis.any?(&.busy)
    end
  end
end
