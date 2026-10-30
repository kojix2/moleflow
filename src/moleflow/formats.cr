require "json"
require "file_utils"
require "pod5"

module Moleflow
  # File conversion is separate from the live simulation and owns one read at a time.
  module Formats
    class OutputConfig
      include JSON::Serializable
      getter scale : Float64
      getter offset : Float64
      getter sample_rate : UInt16
      getter seed : UInt64
    end

    class OutputRow
      include JSON::Serializable
      getter read_id : String
      getter sample_count : Int64
      getter channel : UInt32
      getter number : UInt32
      getter start_sample : UInt64
      getter end_reason : String
    end

    SCALE  = 0.1462070643901825
    OFFSET =             -243.0

    def self.convert(directory : String, destination : String) : Nil
      raise "destination must end in .pod5" unless File.extname(destination) == ".pod5"
      raise "destination already exists" if File.exists?(destination)
      config = OutputConfig.from_json(File.read(File.join(directory, "config.json")))
      scale = config.scale.to_f32
      offset = config.offset.to_f32
      run = Pod5::RunInfo.new(acquisition_id: "moleflow-#{config.seed}",
        sample_rate: config.sample_rate.to_u16, adc_min: Int16::MIN, adc_max: Int16::MAX,
        acquisition_start_time_ms: 1767225600000_i64, protocol_start_time_ms: 1767225600000_i64,
        experiment_name: "moleflow-simulation", flow_cell_id: "MOLEFLOW",
        flow_cell_product_code: "FLO-MIN114", protocol_name: "moleflow",
        protocol_run_id: "moleflow-#{config.seed}", sample_id: "simulated",
        sequencing_kit: "SQK-LSK114", sequencer_position: "MOLEFLOW",
        sequencer_position_type: "simulation", software: "moleflow",
        system_name: "simulation", system_type: "simulation",
        context_tags: {"experiment_type" => "genomic_dna", "sample_frequency" => run_rate(config)},
        tracking_id: {"simulation" => "true"})
      temporary = "#{destination}.#{UUID.random}.tmp"
      begin
        Pod5::Writer.open(temporary) do |writer|
          File.each_line(File.join(directory, "reads.jsonl")) do |line|
            row = OutputRow.from_json(line)
            count = row.sample_count
            next if count == 0
            raise "invalid sample count" unless 0 < count <= Int32::MAX
            id = UUID.new(row.read_id)
            path = File.join(directory, "signal", "#{id}.i16")
            raise "signal length mismatch" unless File.size(path) == count * 2
            signal = Slice(Int16).new(count.to_i)
            File.open(path) { |file| transfer_adc(file, signal, writing: false) }
            reason = case row.end_reason
                     when "unblock_mux_change" then Pod5::EndReason::UnblockMuxChange
                     when "signal_positive"    then Pod5::EndReason::SignalPositive
                     else                           Pod5::EndReason::ApiRequest
                     end
            metadata = Pod5::Metadata.new(read_id: id, run_info: run,
              channel: row.channel, read_number: row.number,
              start_sample: row.start_sample, median_before: 100_f32,
              calibration_offset: offset, calibration_scale: scale,
              end_reason: reason, end_reason_forced: !reason.signal_positive?)
            writer.add(metadata, signal)
          end
        end
        # Install without replacing an existing destination (also in a race).
        File.link(temporary, destination)
      ensure
        File.delete(temporary) if File.exists?(temporary)
      end
    end

    private def self.transfer_adc(io : IO, signal : Slice(Int16), writing : Bool) : Nil
      if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian
        offset = 0
        while offset < signal.size
          count = Math.min(32768, signal.size - offset)
          bytes = (signal.to_unsafe + offset).as(UInt8*).to_slice(count * 2)
          writing ? io.write(bytes) : io.read_fully(bytes)
          offset += count
        end
      else
        signal.size.times do |index|
          if writing
            io.write_bytes(signal[index], IO::ByteFormat::LittleEndian)
          else
            signal[index] = io.read_bytes(Int16, IO::ByteFormat::LittleEndian)
          end
        end
      end
    end

    private def self.run_rate(config : OutputConfig) : String
      config.sample_rate.to_s
    end

    def self.prepare(source : String, destination : String, limit : Int32 = 1000) : Nil
      raise "limit must be positive" unless limit > 0
      Dir.mkdir(destination)
      begin
        samples = [] of NamedTuple(path: String, replay: Bool)
        sample_rate = 0
        Pod5::Reader.open(source) do |reader|
          reader.each do |read|
            break if samples.size >= limit
            next if read.sample_count == 0
            rate = read.run_info.sample_rate.to_i
            raise "mixed sample rates are not supported" unless sample_rate == 0 || sample_rate == rate
            sample_rate = rate
            path = File.expand_path(File.join(destination, "#{read.read_id}.i16"))
            raise "duplicate read ID" if File.exists?(path)
            signal = read.signal
            File.open(path, "w") do |file|
              signal.each_with_index do |adc, index|
                value = (((adc.to_f64 + read.calibration_offset) * read.calibration_scale) / SCALE - OFFSET).round_even
                raise "calibration conversion would clip" unless value.finite? && -32768 <= value <= 32767
                signal[index] = value.to_i16
              end
              transfer_adc(file, signal, writing: true)
            end
            samples << {path: path, replay: true}
          end
        end
        raise "no reads selected" if samples.empty?
        config = {samples: samples, sample_rate: sample_rate, scale: SCALE, offset: OFFSET,
                  channels: 512, workers: 4, duration_seconds: 60}
        File.write(File.join(destination, "replay.json"), config.to_pretty_json + "\n")
      rescue ex
        FileUtils.rm_rf(destination)
        raise ex
      end
    end
  end
end
