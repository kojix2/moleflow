require "./noise"

module Moleflow
  class Model
    MAX_ADAPTER_BYTES = 1024 * 1024
    getter k : Int32
    getter means : Array(Float64)
    getter toy : Bool
    getter prefix : Bytes

    def initialize(path : String?, adapter_path : String? = nil)
      @prefix = load_prefix(adapter_path)
      @k = 3
      @means = [] of Float64
      @toy = path.nil?
      if path
        File.each_line(path) do |line|
          next if line.starts_with?("#") || line.strip.empty?
          fields = line.split
          next unless fields.size >= 2 && fields[0].matches?(/\A[ACGT]+\z/)
          seq, value = fields[0], fields[1].to_f
          if @means.empty?
            @k = seq.size
            raise "model k must be 1..9" unless (1..9).includes?(@k)
            @means = Array(Float64).new(1 << (2 * @k), Float64::NAN)
          end
          raise "invalid model row" unless seq.size == @k && value.finite?
          id = 0
          seq.each_byte { |b| id = (id << 2) | self.class.base(b) }
          raise "duplicate kmer" unless @means[id].nan?
          @means[id] = value
        end
        raise "empty kmer model" if @means.empty?
        raise "incomplete kmer model" if @means.any?(&.nan?)
      else
        @means = Array(Float64).new(64) { |i| 65.0 + i * 0.8 }
      end
    end

    private def load_prefix(path : String?) : Bytes
      return Bytes.empty unless path
      # Bound the read itself: checking File.read(...).size is already too late.
      buffer = Bytes.new(MAX_ADAPTER_BYTES + 1)
      size = File.open(path, &.read_greedy(buffer))
      raise "adapter_signal must be Int16 LE and <= 1 MiB" if size.odd? || size > MAX_ADAPTER_BYTES
      buffer[0, size].dup
    end

    def self.base(b : UInt8) : Int32
      case b
      when 65, 97           then 0
      when 67, 99           then 1
      when 71, 103          then 2
      when 84, 116, 85, 117 then 3
      else                       -1
      end
    end
  end
end
