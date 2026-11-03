require "json"

module Moleflow
  # Typed metadata shared by recording consumers and file converters.
  record RecordedRead, read_id : String, channel : UInt32, number : UInt64,
    start_sample : UInt64, sample_count : Int64, end_reason : String do
    include JSON::Serializable
  end

  # Incremental access to flushed reads. The completion marker is written only
  # after a successful close, so consumers can drain a naturally ended run.
  class Recording
    COMPLETE_FILE = "recording.complete"
    getter directory : String
    @position = 0_i64

    def initialize(directory : String)
      @directory = File.expand_path(directory)
    end

    def read_available(& : RecordedRead ->) : Nil
      return unless File.file?(summary_path)
      File.open(summary_path) do |file|
        file.seek(@position)
        while line = file.gets(limit: 1_048_577, chomp: false)
          raise ArgumentError.new("oversized recording metadata") if line.bytesize > 1_048_576
          break unless line.ends_with?('\n')
          row = RecordedRead.from_json(line)
          yield row
          @position = file.pos
        end
      end
    end

    def complete? : Bool
      File.file?(File.join(directory, COMPLETE_FILE))
    end

    def drained? : Bool
      complete? && File.file?(summary_path) && File.size(summary_path) == @position
    end

    def signal_path(read : RecordedRead) : String
      id = read.read_id
      raise ArgumentError.new("invalid read identifier") if id.empty? || id == "." || id == ".." || File.basename(id) != id
      File.join(directory, "signal", "#{id}.i16")
    end

    def read_signal(read : RecordedRead, *, max_bytes : Int32) : Bytes
      path = signal_path(read)
      size = File.size(path)
      raise ArgumentError.new("recorded signal exceeds analysis limit") unless 0 < size <= max_bytes
      raise ArgumentError.new("recorded signal length mismatch") unless 0 < read.sample_count <= max_bytes // 2 && size == read.sample_count * 2
      File.open(path) do |file|
        bytes = Bytes.new(size.to_i)
        file.read_fully(bytes)
        bytes
      end
    end

    private def summary_path : String
      File.join(directory, "reads.jsonl")
    end
  end
end
