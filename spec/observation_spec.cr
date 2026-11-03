require "spec"
require "file_utils"
require "../src/moleflow/application"

class RecordingObserver < Moleflow::Observer
  getter progress = [] of Moleflow::ReadProgress
  getter closed = [] of String
  getter callback_threads = [] of UInt64

  def on_progress(read : Moleflow::ReadProgress) : Nil
    @progress << read
    @callback_threads << Thread.current.object_id
  end

  def on_recording_closed(directory : String) : Nil
    raise "unflushed recording" unless Moleflow::Recording.new(directory).complete?
    @closed << directory
    @callback_threads << Thread.current.object_id
  end
end

describe "Physical progress observations" do
  it "snapshots accepted reads independently of delivery and records truncated ejections" do
    config = Moleflow::Config.from_json({samples: [{path: "examples/reference.fa", circular: true}],
                                         channels: 1, sample_rate: 4000, mean_read_length: 1000, read_length_sigma: 0}.to_json)
    model = Moleflow::Model.new(nil)
    sources = Moleflow::Source.load(config, model)
    engine = Moleflow::Engine.new(config, sources, model, [1], observe: true)
    original = engine.tick(0).progress.first
    engine.action(Moleflow::Action.new(1, original.read_id, false), 100_i64).should eq(0)
    tick = engine.tick(1000)
    tick.chunks.should be_empty
    tick.progress.first.samples.should eq(1000)
    original.samples.should eq(0)
    terminal = engine.tick(original.total_samples).progress.find! { |read| read.read_id == original.read_id }
    terminal.end_reason.should eq("signal_positive")
    terminal.samples.should eq(terminal.total_samples)

    rejected = Moleflow::Engine.new(config, sources, model, [1], observe: true)
    read = rejected.tick(0).progress.first
    rejected.action(Moleflow::Action.new(1, read.read_id, true), 100_i64).should eq(0)
    ejected = rejected.tick(100).progress.find! { |item| item.read_id == read.read_id }
    ejected.end_reason.should eq("unblock_mux_change")
    ejected.samples.should eq(100)
    ejected.samples.should be < ejected.total_samples
    Moleflow::Engine.new(config, sources, model, [1]).tick(0).progress.should be_empty
  end

  it "runs observer callbacks on the coordinator and closes only flushed recording output" do
    directory = File.tempname("moleflow-observe")
    config = Moleflow::Config.from_json({samples: [{path: "examples/reference.fa", circular: true}],
                                         channels: 2, workers: 2, sample_rate: 4000, mean_read_length: 100,
                                         read_length_sigma: 0, duration_seconds: 1, output: directory}.to_json)
    observer = RecordingObserver.new
    model = Moleflow::Model.new(nil)
    begin
      Moleflow::Application.new(config, Moleflow::Source.load(config, model), model, observer).simulate
      observer.progress.map(&.channel).uniq!.sort!.should eq([1, 2])
      observer.progress.any? { |read| !read.end_reason.empty? }.should be_true
      observer.closed.should eq([directory])
      observer.callback_threads.uniq.should eq([Thread.current.object_id])
      recording = Moleflow::Recording.new(directory)
      rows = [] of Moleflow::RecordedRead
      recording.read_available { |read| rows << read }
      rows.size.should be > 0
      recording.drained?.should be_true
      recording.read_signal(rows.first, max_bytes: 100000).size.should eq(rows.first.sample_count * 2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe Moleflow::Recording do
  it "does not mark failed writes as a complete recording" do
    directory = File.tempname("moleflow-failed-recording")
    config = Moleflow::Config.from_json({samples: [{path: "examples/reference.fa", circular: true}],
                                         channels: 1, output: directory}.to_json)
    output = Moleflow::Output.new(config)
    model = Moleflow::Model.new(nil)
    engine = Moleflow::Engine.new(config, Moleflow::Source.load(config, model), model, [1])
    begin
      FileUtils.rm_rf(File.join(directory, "signal"))
      expect_raises(File::NotFoundError) { output.consume(engine.tick(100)) }
      output.close
      Moleflow::Recording.new(directory).complete?.should be_false
    ensure
      output.close
      FileUtils.rm_rf(directory)
    end
  end

  it "waits for complete metadata lines, skips unsigned seeds, and validates signal boundaries" do
    directory = File.tempname("moleflow-recording")
    Dir.mkdir(directory)
    Dir.mkdir(File.join(directory, "signal"))
    summary = File.join(directory, "reads.jsonl")
    line = {read_id: "read", channel: 1, number: 1, start_sample: 0,
            sample_count: 2, end_reason: "signal_positive", seed: UInt64::MAX}.to_json
    reader = Moleflow::Recording.new(directory)
    rows = [] of Moleflow::RecordedRead
    begin
      File.write(summary, line[0, 20])
      reader.read_available { |read| rows << read }
      rows.should be_empty
      File.open(summary, "a") { |file| file << line[20..] << '\n' }
      reader.read_available { |read| rows << read }
      reader.read_available { |read| rows << read }
      rows.size.should eq(1)
      reader.drained?.should be_false
      File.write(File.join(directory, Moleflow::Recording::COMPLETE_FILE), "")
      reader.drained?.should be_true
      File.write(File.join(directory, "signal", "read.i16"), Bytes[0, 0, 1, 0])
      reader.read_signal(rows.first, max_bytes: 4).should eq(Bytes[0, 0, 1, 0])
      expect_raises(ArgumentError, /limit/) { reader.read_signal(rows.first, max_bytes: 2) }
      File.write(File.join(directory, "signal", "read.i16"), Bytes[0, 0])
      expect_raises(ArgumentError, /length mismatch/) { reader.read_signal(rows.first, max_bytes: 4) }
      bad = Moleflow::RecordedRead.new("../escape", 1_u32, 1_u64, 0_u64, 2_i64, "signal_positive")
      expect_raises(ArgumentError, /identifier/) { reader.signal_path(bad) }
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
