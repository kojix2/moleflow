require "./engine"

module Moleflow
  # Single owner; raw chunks are appended immediately, never buffered for entire reads.
  class Output
    @summary : File?
    getter completed : Int64 = 0_i64
    getter samples : Int64 = 0_i64

    def initialize(@config : Config)
      if dir = @config.output
        raise "output already exists: #{dir}" if File.exists?(dir)
        Dir.mkdir_p(File.dirname(dir))
        # Claim the run directory atomically before writing any recording files.
        Dir.mkdir(dir)
        Dir.mkdir(File.join(dir, "signal"))
        File.write(File.join(dir, "config.json"), @config.to_pretty_json)
        @summary = File.open(File.join(dir, "reads.jsonl"), "w")
      end
    end

    def consume(tick : Tick)
      tick.chunks.each do |chunk|
        @samples += chunk.data.size // 2
        if dir = @config.output
          path = File.join(dir, "signal", "#{chunk.read.id}.i16")
          File.open(path, "a", &.write(chunk.data))
        end
      end
      tick.finished.each do |f|
        @completed += 1
        if summary = @summary
          read = f.read
          summary.puts({read_id:      read.id,
                        channel:      read.channel,
                        number:       read.number,
                        source:       read.source.name,
                        origin:       read.origin,
                        reverse:      read.reverse,
                        start_sample: read.start,
                        sample_count: f.samples,
                        end_reason:   f.reason,
                        seed:         read.seed}.to_json)
          summary.flush
        end
      end
    end

    def close
      @summary.try &.close
    end
  end
end
