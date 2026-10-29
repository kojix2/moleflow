require "digest/sha256"
require "./source"

module Moleflow
  class Molecule
    getter id : String
    getter channel : Int32
    getter number : UInt64
    getter source : Source
    getter origin : Int32
    getter reverse : Bool
    getter length : Int64
    getter start : Int64
    getter seed : UInt64
    property cursor : Int64 = 0_i64
    property stopped : Bool = false

    def initialize(@channel, @number, @source, @origin, @reverse, @length, @start, @seed)
      hex = Digest::SHA256.hexdigest("#{seed}:#{channel}:#{number}")[0, 32]
      @id = "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-a#{hex[17, 3]}-#{hex[20, 12]}"
    end

    def signal(from : Int64, count : Int32, config : Config, model : Model) : Bytes
      buffer = Bytes.new(count * 2)
      if source.replay
        File.open(source.path) do |f|
          f.seek(from * 2)
          f.read_fully(buffer)
        end
      else
        previous = -1_i64
        mean = 0.0
        count.times do |i|
          pos = from + i
          if pos < model.prefix.size // 2
            buffer[i * 2, 2].copy_from(model.prefix[pos * 2, 2])
            next
          end
          pos -= model.prefix.size // 2
          base_pos = (pos * config.sequencing_speed / config.sample_rate).floor.to_i64
          if base_pos != previous
            code = 0
            model.k.times do |j|
              idx = origin.to_i64 + (reverse ? -(base_pos + j) : base_pos + j)
              idx %= source.sequence.size if source.circular
              idx = idx.clamp(0_i64, source.sequence.size.to_i64 - 1)
              b = Model.base(source.sequence[idx])
              b = (Noise.mix(seed &+ idx.to_u64) & 3).to_i if b < 0
              b = 3 - b if reverse
              code = (code << 2) | b
            end
            mean = model.means[code]
            previous = base_pos
          end
          pa = mean + config.noise_pa * Noise.normal(seed, pos.to_u64)
          adc = (pa / config.scale - config.offset).round.clamp(-32768.0, 32767.0).to_i16
          IO::ByteFormat::LittleEndian.encode(adc, buffer[i*2, 2])
        end
      end
      buffer
    end
  end
end
