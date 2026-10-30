require "spec"
require "file_utils"
require "../src/moleflow/formats"

private def format_temp(&)
  directory = File.join(Dir.tempdir, "moleflow-pod5-#{UUID.random}")
  Dir.mkdir(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def format_input(directory, count = 4)
  input = File.join(directory, "input")
  Dir.mkdir(input)
  Dir.mkdir(File.join(input, "signal"))
  id = UUID.random
  File.write(File.join(input, "config.json"), {sample_rate: 5000, seed: 42, scale: 0.25, offset: -12.5}.to_json)
  File.write(File.join(input, "reads.jsonl"), {read_id: id.to_s, sample_count: count, molecule_seed: UInt64::MAX, channel: 2, number: 7, start_sample: 123, end_reason: "unblock_mux_change"}.to_json + "\n")
  File.open(File.join(input, "signal", "#{id}.i16"), "w") do |file|
    [-32768_i16, -1_i16, 0_i16, 32767_i16].each { |value| file.write_bytes(value, IO::ByteFormat::LittleEndian) }
  end
  {input, id}
end

describe Moleflow::Formats do
  it "preserves ADC bytes and metadata and refuses replacement" do
    format_temp do |directory|
      input, id = format_input(directory)
      output = File.join(directory, "output.pod5")
      Moleflow::Formats.convert(input, output)
      Pod5::Reader.open(output) do |reader|
        read = reader[id]
        read.signal.to_a.should eq([-32768, -1, 0, 32767])
        read.channel.should eq(2)
        read.start_sample.should eq(123)
        read.read_number.should eq(7)
        read.calibration_scale.should eq(0.25)
        read.calibration_offset.should eq(-12.5)
        read.end_reason.should eq(Pod5::EndReason::UnblockMuxChange)
        read.end_reason_forced.should be_true
      end
      expect_raises(Exception, /already exists/) { Moleflow::Formats.convert(input, output) }
      expect_raises(Exception, /\.pod5/) { Moleflow::Formats.convert(input, File.join(directory, "out.fast5")) }
    end
  end

  it "does not install a partial POD5 when the signal length is wrong" do
    format_temp do |directory|
      input, _ = format_input(directory, 5)
      output = File.join(directory, "output.pod5")
      expect_raises(Exception, /length mismatch/) { Moleflow::Formats.convert(input, output) }
      File.exists?(output).should be_false
    end
  end

  it "rejects clipping and removes incomplete replay output" do
    format_temp do |directory|
      source = File.join(directory, "clip.pod5")
      run = Pod5::RunInfo.new(acquisition_id: "test", sample_rate: 5000_u16)
      Pod5::Writer.open(source) do |writer|
        writer.add(Pod5::Metadata.new(run_info: run, channel: 1_u32, calibration_scale: 2_f32), Slice[32767_i16])
      end
      output = File.join(directory, "replay")
      expect_raises(Exception, /clip/) { Moleflow::Formats.prepare(source, output) }
      Dir.exists?(output).should be_false
    end
  end

  it "rejects mixed sampling rates" do
    format_temp do |directory|
      source = File.join(directory, "mixed.pod5")
      Pod5::Writer.open(source) do |writer|
        [4000_u16, 5000_u16].each do |rate|
          run = Pod5::RunInfo.new(acquisition_id: "rate-#{rate}", sample_rate: rate)
          writer.add(Pod5::Metadata.new(run_info: run, channel: 1_u32), Slice[0_i16])
        end
      end
      output = File.join(directory, "replay")
      expect_raises(Exception, /mixed sample/) { Moleflow::Formats.prepare(source, output) }
      Dir.exists?(output).should be_false
    end
  end
end

it "round trips signals across the 64 KiB I/O boundary" do
  format_temp do |directory|
    input, id = format_input(directory, 32769)
    signal = Slice(Int16).new(32769) { |i| (i % 701 - 350).to_i16 }
    File.open(File.join(input, "signal", "#{id}.i16"), "w") do |file|
      signal.each { |adc| file.write_bytes(adc, IO::ByteFormat::LittleEndian) }
    end
    output = File.join(directory, "boundary.pod5")
    Moleflow::Formats.convert(input, output)
    Pod5::Reader.open(output, &.[id].signal.should(eq(signal)))
    replay = File.join(directory, "replay")
    Moleflow::Formats.prepare(output, replay)
    File.open(File.join(replay, "#{id}.i16")) do |file|
      signal.each do |adc|
        expected = (((adc.to_f64 - 12.5) * 0.25) / Moleflow::Formats::SCALE - Moleflow::Formats::OFFSET).round_even.to_i16
        file.read_bytes(Int16, IO::ByteFormat::LittleEndian).should eq(expected)
      end
      file.read_byte.should be_nil
    end
  end
end
