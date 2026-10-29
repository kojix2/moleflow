require "./stream_settings"
require "./response_encoder"
require "./async_output"
require "./worker_pool"

module Moleflow
  # One coordinator owns the clock, settings and ordering of worker commands.
  class LiveSession
    MAX_REQUEST_BYTES = 1024 * 1024
    SETUP_TIMEOUT     = 10.seconds
    SEND_TIMEOUT      = 1.second
    DRAIN_TIMEOUT     = 6.seconds

    @encoder : ResponseEncoder
    @inbox = Channel(D::GetLiveReadsRequest).new(64)
    @failure = Channel(Exception).new(1)
    @outgoing : Channel(D::GetLiveReadsResponse)
    @sender_result = Channel(Exception?).new(1)

    def initialize(@config : Config, @sources : Array(Source), @model : Model)
      @encoder = ResponseEncoder.new(config)
      @outgoing = Channel(D::GetLiveReadsResponse).new(config.stream_queue)
    end

    def run(requests : GRPC::RawRequestStream, ctx : GRPC::ServerContext,
            writer : GRPC::RawResponseStream) : GRPC::Status
      spawn { receive_requests(requests) }
      spawn { send_responses(writer) }
      pool = nil
      output = nil
      problem = nil
      begin
        setup = initial_setup
        dtype, max_samples = StreamSettings.validate(setup, 3, @config)
        output = AsyncOutput.new(@config)
        pool = Pool.new(@config, @sources, @model)
        simulate(ctx, pool, output, setup, dtype, max_samples)
      rescue ex
        problem = ex
      ensure
        begin
          finish_output(pool, output)
        rescue ex
          problem ||= ex
        ensure
          @inbox.close
          @outgoing.close
          # The last tick may finish before the sender fails. Check its result
          # before reporting a successful RPC.
          send_error = await_sender(ctx)
          problem ||= send_error
          @encoder.clear
        end
      end
      raise problem if problem
      GRPC::Status.ok
    end

    private def receive_requests(requests : GRPC::RawRequestStream) : Nil
      requests.each do |bytes|
        if bytes.size > MAX_REQUEST_BYTES
          raise GRPC::StatusError.new(GRPC::StatusCode::RESOURCE_EXHAUSTED, "request too large")
        end
        @inbox.send(D::GetLiveReadsRequest.decode(bytes))
      end
    rescue ex : Channel::ClosedError
      report_failure(ex) unless @inbox.closed?
    rescue ex
      report_failure(ex)
    ensure
      @inbox.close
    end

    private def send_responses(writer : GRPC::RawResponseStream) : Nil
      problem = nil
      begin
        while response = @outgoing.receive?
          writer.send_raw(response.encode)
        end
      rescue ex
        problem = ex
        report_failure(ex)
      ensure
        @sender_result.send(problem)
      end
    end

    private def report_failure(error : Exception) : Nil
      select
      when @failure.send(error)
      else
      end
    end

    private def initial_setup : D::GetLiveReadsRequest::StreamSetup
      first = select
      when message = @inbox.receive?
        message
      when error = @failure.receive
        raise error
      when timeout(SETUP_TIMEOUT)
        raise GRPC::StatusError.new(GRPC::StatusCode::DEADLINE_EXCEEDED, "setup timeout")
      end
      first.try(&.setup) || raise GRPC::StatusError.new(
        GRPC::StatusCode::INVALID_ARGUMENT, "first message must be setup")
    end

    private def simulate(ctx, pool, output, setup, dtype, max_samples) : Nil
      start = Time.instant
      next_tick = start
      end_at = (@config.duration_seconds * @config.sample_rate).to_i64
      loop do
        break if ctx.cancelled?
        now = Time.instant
        sample = Math.min(end_at, elapsed_samples(start))
        if now >= next_tick
          tick = pool.tick(sample)
          output.consume(tick)
          @encoder.encode(tick, sample, setup, dtype).each { |response| enqueue(response) }
          break if sample >= end_at
          next_tick += @config.chunk_ms.milliseconds
        end
        wait = Math.max(next_tick - Time.instant, 1.millisecond)
        select
        when error = @failure.receive
          raise error
        when message = @inbox.receive?
          break unless message
          if updated = message.setup
            dtype, max_samples = StreamSettings.validate(updated, dtype, @config)
            setup = updated
            @encoder.clear
          end
          if actions = message.actions
            apply_actions(actions, pool, output, start, max_samples)
          end
        when timeout(wait)
        end
      end
    end

    private def elapsed_samples(start : Time::Instant) : Int64
      ((Time.instant - start).total_seconds * @config.sample_rate).to_i64
    end

    private def apply_actions(actions, pool, output, start, max_samples) : Nil
      if actions.actions.size > @config.channels * 2
        raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "too many actions")
      end
      response = D::GetLiveReadsResponse.new
      actions.actions.each do |request|
        action = validate_action(request, max_samples)
        reply = pool.action(action, elapsed_samples(start))
        @encoder.discard(action.channel) if reply.status == 0 || reply.status == 2
        output.consume((reply.tick || raise "worker returned no tick"))
        response.action_responses << Moleflow.pb(D::GetLiveReadsResponse::ActionResponse,
          action_id: request.action_id,
          response: Proto::OpenEnum(D::GetLiveReadsResponse::ActionResponse::Response).new(reply.status))
      end
      enqueue(response)
    end

    private def validate_action(request : D::GetLiveReadsRequest::Action, max_samples : Int64) : Action
      ProtocolValidation.channels!(request.channel, request.channel, @config.channels)
      if request.id.empty? || (!request.unblock && !request.stop_further_data)
        raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "action requires read ID and operation")
      end
      duration = request.unblock.try(&.duration) || 0.0
      unless duration.finite? && (0.0..60.0).includes?(duration)
        raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "invalid unblock duration")
      end
      Action.new(request.channel.to_i, request.id, !request.unblock.nil?, duration, max_samples)
    end

    private def finish_output(pool : Pool?, output : AsyncOutput?) : Nil
      output.try &.consume(pool.close) if pool
    ensure
      output.try &.close
    end

    private def await_sender(ctx : GRPC::ServerContext) : Exception?
      select
      when error = @sender_result.receive
        error
      when timeout(DRAIN_TIMEOUT)
        ctx.cancel
        GRPC::StatusError.new(GRPC::StatusCode::RESOURCE_EXHAUSTED, "response drain timed out")
      end
    end

    private def enqueue(response : D::GetLiveReadsResponse) : Nil
      select
      when @outgoing.send(response)
      when timeout(SEND_TIMEOUT)
        raise GRPC::StatusError.new(GRPC::StatusCode::RESOURCE_EXHAUSTED, "client cannot keep up with real-time signal")
      end
    end
  end
end
