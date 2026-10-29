require "./engine"

module Moleflow
  record Job, time : Int64 = 0_i64, action : Action? = nil, stop : Bool = false
  record Reply, tick : Tick? = nil, status : Int32 = 0, error : Exception? = nil

  class Pool
    @inboxes : Array(Channel(Job))
    @outboxes : Array(Channel(Reply))
    @context : Fiber::ExecutionContext::Parallel
    @closed = false
    @channels : Int32

    def initialize(config : Config, sources : Array(Source), model : Model)
      @channels = config.channels
      n = Math.min(config.workers, config.channels)
      @context = Fiber::ExecutionContext::Parallel.new("signal", n)
      @inboxes = Array.new(n) { Channel(Job).new(1) }
      @outboxes = Array.new(n) { Channel(Reply).new(1) }
      n.times do |i|
        engine = Engine.new(config, sources, model, (1..config.channels).select { |ch| (ch - 1) % n == i })
        input, output = @inboxes[i], @outboxes[i]
        @context.spawn do
          while job = input.receive?
            begin
              if job.stop
                output.send(Reply.new(tick: engine.shutdown))
                break
              elsif a = job.action
                status = engine.action(a, job.time)
                output.send(Reply.new(tick: Tick.new(engine.tails, [] of Finished), status: status))
              else
                output.send(Reply.new(tick: engine.tick(job.time)))
              end
            rescue ex
              output.send(Reply.new(error: ex))
            end
          end
        end
      end
    end

    def tick(at : Int64) : Tick
      ensure_open!
      @inboxes.each(&.send(Job.new(time: at)))
      combine
    end

    def action(action : Action, at : Int64) : Reply
      ensure_open!
      raise ArgumentError.new("invalid channel") unless (1..@channels).includes?(action.channel)
      index = (action.channel - 1) % @inboxes.size
      @inboxes[index].send(Job.new(time: at, action: action))
      reply = @outboxes[index].receive
      if error = reply.error
        raise error
      end
      reply
    end

    private def combine : Tick
      replies = @outboxes.map(&.receive)
      replies.each do |reply|
        if error = reply.error
          raise error
        end
      end
      Tick.new(replies.flat_map { |reply| (reply.tick || raise "worker returned no tick").chunks }, replies.flat_map { |reply| (reply.tick || raise "worker returned no tick").finished })
    end

    def close : Tick
      return Tick.new([] of Chunk, [] of Finished) if @closed
      @closed = true
      @inboxes.each(&.send(Job.new(stop: true)))
      combine
    end

    private def ensure_open! : Nil
      raise "worker pool is closed" if @closed
    end
  end
end
