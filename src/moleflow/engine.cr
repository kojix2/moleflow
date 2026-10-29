require "./config"
require "./molecule"

module Moleflow
  record Chunk, read : Molecule, from : Int64, data : Bytes
  record Finished, read : Molecule, samples : Int64, reason : String
  record Tick, chunks : Array(Chunk), finished : Array(Finished)
  record Action, channel : Int32, read_id : String, unblock : Bool, duration : Float64 = 0.1, max_samples : Int64 = Int64::MAX

  class Pore
    getter channel : Int32
    getter rng : Random::PCG32
    property read : Molecule? = nil
    property next_at : Int64 = 0_i64
    property dead : Bool = false
    property number : UInt64 = 0_u64

    def initialize(@channel, seed : UInt64, working : Float64)
      @rng = Random::PCG32.new(Noise.mix(seed &+ channel.to_u64))
      @dead = rng.rand >= working
    end
  end

  class Engine
    @total_weight : Float64
    getter pores : Array(Pore)
    @pending = [] of Finished
    @tail = [] of Chunk
    @last_tick = 0_i64

    def initialize(@config : Config, @sources : Array(Source), @model : Model, channels : Enumerable(Int32))
      @pores = channels.map { |ch| Pore.new(ch, @config.seed, @config.working_fraction) }.to_a
      @total_weight = @sources.sum(&.weight)
    end

    def start_read(pore : Pore, at : Int64) : Molecule
      choice = pore.rng.rand * @total_weight
      source = @sources.last
      @sources.each do |candidate|
        choice -= candidate.weight
        if choice <= 0
          source = candidate
          break
        end
      end
      pore.number += 1
      seed = pore.rng.rand(UInt64)
      origin = source.replay ? 0 : pore.rng.rand(source.sequence.size)
      reverse = pore.rng.rand < 0.5
      bases = (@config.mean_read_length * Math.exp(@config.read_length_sigma * Noise.normal(seed, 0_u64) - @config.read_length_sigma ** 2 / 2)).clamp(1.0, @config.max_read_bases.to_f).to_i64
      unless source.replay || source.circular
        bases = Math.min(bases, reverse ? origin.to_i64 + 1 : source.sequence.size.to_i64 - origin)
      end
      length = source.replay ? source.samples : (bases * @config.sample_rate / @config.sequencing_speed).ceil.to_i64
      length += @model.prefix.size // 2 unless source.replay
      Molecule.new(pore.channel, pore.number, source, origin, reverse, length, at, seed)
    end

    def tick(now : Int64, emit : Bool = true) : Tick
      raise ArgumentError.new("sample time must not go backwards") if now < @last_tick
      if now - @last_tick > @config.max_chunk_samples
        raise "simulation fell behind: tick exceeds max_chunk_samples"
      end
      @last_tick = now
      chunks = [] of Chunk
      finished = @pending
      @pending = [] of Finished
      pores.each do |pore|
        next if pore.dead
        loop do
          break if !pore.read && now < pore.next_at
          pore.read ||= start_read(pore, pore.next_at) if now >= pore.next_at
          if read = pore.read
            available = Math.min(read.length, Math.max(0_i64, now - read.start))
            count = available - read.cursor
            raise "simulation fell behind: chunk exceeds max_chunk_samples" if count > @config.max_chunk_samples
            if count > 0
              if (emit && !read.stopped) || @config.output
                chunks << Chunk.new(read, read.cursor, read.signal(read.cursor, count.to_i, @config, @model))
              end
              read.cursor = available
            end
            if read.cursor >= read.length
              finished << Finished.new(read, read.cursor, "signal_positive")
              finish(pore, read.start + read.length, 0.0)
              break if pore.dead
            else
              break
            end
          end
        end
      end
      Tick.new(chunks, finished)
    end

    def finish(pore : Pore, at : Int64, unblock_duration : Float64)
      pore.read = nil
      pore.dead = pore.rng.rand < @config.death_probability
      gap = @config.reacquire_seconds == 0 ? 0.0 : -Math.log(1.0 - pore.rng.rand) * @config.reacquire_seconds
      pore.next_at = at + ((gap + unblock_duration) * @config.sample_rate).ceil.to_i64
    end

    # Application is serialized by the worker owner; stale IDs never affect a successor.
    def action(action : Action, now : Int64) : Int32
      pore = pores.find { |pore| pore.channel == action.channel }
      return 1 unless pore
      read = pore.read
      return 1 unless read && read.id == action.read_id && now < read.start + read.length
      if action.unblock && now - read.start > action.max_samples
        read.stopped = true
        return 2
      end
      if action.unblock
        available = Math.min(read.length, Math.max(read.cursor, now - read.start))
        # Capture the unsent tail for output, without promising it to the client.
        if @config.output && available > read.cursor
          raise "unblock tail exceeds max_chunk_samples" if available - read.cursor > @config.max_chunk_samples
          @tail << Chunk.new(read, read.cursor, read.signal(read.cursor, (available - read.cursor).to_i, @config, @model))
        end
        read.cursor = available
        @pending << Finished.new(read, available, "unblock_mux_change")
        finish(pore, now, action.duration)
      else
        read.stopped = true
      end
      0
    end

    def tails : Array(Chunk)
      result = @tail
      @tail = [] of Chunk
      result
    end

    def shutdown : Tick
      finished = @pending
      @pending = [] of Finished
      pores.each do |pore|
        if r = pore.read
          finished << Finished.new(r, r.cursor, "simulation_end")
          pore.read = nil
        end
      end
      Tick.new(tails, finished)
    end
  end
end
