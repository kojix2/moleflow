require "./config"
require "./model"

module Moleflow
  class Source
    getter name : String
    getter path : String
    getter sequence : Bytes
    getter samples : Int64
    getter weight : Float64
    getter circular : Bool
    getter replay : Bool

    def initialize(@name, @path, @sequence, @samples, @weight, @circular, @replay)
    end

    def self.load(config : Config, model : Model) : Array(Source)
      result = [] of Source
      total = 0_i64
      config.samples.each do |sample|
        if sample.replay
          bytes = File.size(sample.path)
          raise "replay must contain little-endian Int16 samples" if bytes == 0 || bytes.odd?
          result << new(File.basename(sample.path), sample.path, Bytes.empty, bytes // 2, sample.weight, false, true)
        else
          # FASTA is retained as one byte/base. Signals are never expanded globally.
          name = ""
          seq = IO::Memory.new
          records = [] of Tuple(String, Bytes)
          File.each_line(sample.path) do |line|
            if line.starts_with?('>')
              records << {name, seq.to_slice.dup} unless name.empty?
              name = line[1..].split.first? || "unnamed"
              seq = IO::Memory.new
            else
              raise "expected FASTA header" if name.empty? && !line.strip.empty?
              line.each_byte do |b|
                next if b.chr.ascii_whitespace?
                total += 1
                raise "reference exceeds max_reference_bytes" if total > config.max_reference_bytes
                code = Model.base(b)
                seq.write_byte(code < 0 ? 78_u8 : "ACGT".to_slice[code])
              end
            end
          end
          records << {name, seq.to_slice.dup} unless name.empty?
          raise "empty FASTA" if records.empty?
          length = records.sum(&.[1].size.to_i64).to_f
          records.each do |n, s|
            raise "contig shorter than kmer model" if s.size < model.k
            result << new(n, sample.path, s, 0_i64, sample.weight * (s.size / length), sample.circular, false)
          end
        end
      end
      result
    end
  end
end
