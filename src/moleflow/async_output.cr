require "./output"

module Moleflow
  # File I/O gets its own execution context. Bounded ownership transfer prevents
  # a slow disk from accumulating complete reads or blocking the gRPC scheduler.
  class AsyncOutput
    CLOSE_TIMEOUT = 6.seconds

    @queue = Channel(Tick).new(4)
    @done = Channel(Exception?).new(1)
    @error = Channel(Exception).new(1)
    @context = Fiber::ExecutionContext::Parallel.new("disk", 1)
    @closed = false

    def initialize(config : Config, output : Output = Output.new(config))
      @context.spawn do
        error = nil
        begin
          while tick = @queue.receive?
            output.consume(tick)
          end
        rescue ex
          error = ex
          @error.send(ex)
          @queue.close
        ensure
          begin
            output.close
          rescue ex
            error ||= ex
          end
          # Notify even when flushing/closing the file itself fails.
          @done.send(error)
        end
      end
    end

    def consume(tick : Tick)
      raise "disk output is closed" if @closed
      select
      when ex = @error.receive
        raise ex
      when @queue.send(tick)
      when timeout(1.second)
        raise "disk output cannot keep up"
      end
    end

    def close
      return if @closed
      @closed = true
      @queue.close
      select
      when error = @done.receive
        raise error if error
      when timeout(CLOSE_TIMEOUT)
        raise "disk output shutdown timed out; output may be incomplete"
      end
    end
  end
end
