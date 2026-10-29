require "spec"
require "file_utils"
require "../src/moleflow/async_output"

class BlockingCloseOutput < Moleflow::Output
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def close
    entered.send(nil)
    release.receive
    super
  end
end

describe "initial audit regressions" do
  it "rejects an empty output path before writing files" do
    config = Moleflow::Config.from_json(%({"samples":[{"path":"examples/reference.fa"}],"output":""}))
    expect_raises(Exception, /output/) { config.validate! }

    directory = File.tempname("moleflow-empty-output", nil)
    Dir.mkdir(directory)
    begin
      Dir.cd(directory) do
        expect_raises(Exception) { Moleflow::Output.new(config) }
        Dir.children(directory).should be_empty
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "preserves existing output and creates missing parent directories" do
    directory = File.tempname("moleflow-output", nil)
    config = Moleflow::Config.from_json(%({"samples":[{"path":"examples/reference.fa"}]}))
    destination = File.join(directory, "nested", "run")
    config.output = destination
    begin
      output = Moleflow::Output.new(config)
      output.close
      path = File.join(destination, "config.json")
      File.write(path, "existing recording")
      expect_raises(Exception) { Moleflow::Output.new(config) }
      File.read(path).should eq("existing recording")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "keeps large finite sample weights proportional to contig length" do
    file = File.tempfile("moleflow-weights")
    begin
      file.puts(">short\nACGT\n>long\nACGTACGT")
      file.close
      config = Moleflow::Config.from_json(%({"samples":[{"path":#{file.path.to_json},"weight":1e308}]}))
      config.validate!
      sources = Moleflow::Source.load(config, Moleflow::Model.new(nil))
      sources.all?(&.weight.finite?).should be_true
      sources.sum(&.weight).should be_close(1e308, 1e293)
      (sources[1].weight / sources[0].weight).should be_close(2.0, 1e-12)
    ensure
      file.close
      File.delete(file.path)
    end
  end

  it "rejects a duration that cannot be represented as a sample time" do
    config = Moleflow::Config.from_json(%({"samples":[{"path":"examples/reference.fa"}],"duration_seconds":1e308}))
    expect_raises(Exception, /duration/) { config.validate! }
  end

  it "reports a stalled disk close within a bounded time" do
    config = Moleflow::Config.from_json(%({"samples":[{"path":"examples/reference.fa"}]}))
    sink = BlockingCloseOutput.new(config)
    output = Moleflow::AsyncOutput.new(config, sink)
    result = Channel(Exception?).new(1)
    spawn do
      output.close
      result.send(nil)
    rescue ex
      result.send(ex)
    end
    sink.entered.receive
    begin
      error = select
      when value = result.receive
        value
      when timeout(8.seconds)
        raise "disk close did not time out"
      end
      problem = error || raise "disk close unexpectedly succeeded"
      (problem.message || "").should contain("disk output shutdown timed out")
    ensure
      sink.release.send(nil)
    end
  end
end
