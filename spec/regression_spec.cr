require "spec"
require "../src/moleflow/live_session"

private def completes_promptly(&block : -> T) : T forall T
  result = Channel(T | Exception).new(1)
  spawn do
    result.send(block.call)
  rescue ex
    result.send(ex)
  end
  select
  when value = result.receive
    raise value if value.is_a?(Exception)
    value
  when timeout(2.seconds)
    raise "operation hung for two seconds"
  end
end

private def regression_fixture
  config = Moleflow::Config.from_json(%({"samples":[{"path":"examples/reference.fa","circular":true}],"channels":1,"workers":1}))
  model = Moleflow::Model.new(nil)
  {config, model, Moleflow::Source.load(config, model)}
end

class CloseFailureOutput < Moleflow::Output
  def close
    raise "injected close failure"
  end
end

describe "cleanup regressions" do
  it "caps catch-up across many short reads before changing pore state" do
    config, model, sources = regression_fixture
    config.mean_read_length = 1
    config.read_length_sigma = 0
    config.reacquire_seconds = 0
    config.max_chunk_samples = 100
    engine = Moleflow::Engine.new(config, sources, model, [1])
    expect_raises(Exception, /tick exceeds/) { engine.tick(1000) }
    engine.pores[0].number.should eq(0)
    engine.tick(100).chunks.sum { |chunk| chunk.data.size // 2 }.should eq(100)
  end

  it "rejects a clock going backwards" do
    config, model, sources = regression_fixture
    engine = Moleflow::Engine.new(config, sources, model, [1])
    engine.tick(100)
    expect_raises(ArgumentError, /backwards/) { engine.tick(99) }
  end

  it "closes workers twice without blocking and rejects subsequent work" do
    config, model, sources = regression_fixture
    pool = Moleflow::Pool.new(config, sources, model)
    pool.tick(0)
    completes_promptly { pool.close }.finished.size.should eq(1)
    completes_promptly { pool.close }.finished.should be_empty
    expect_raises(Exception, /closed/) { pool.tick(100) }
    expect_raises(Exception, /closed/) { pool.action(Moleflow::Action.new(1, "id", true), 100) }
  end

  it "closes asynchronous output twice without blocking" do
    config, _, _ = regression_fixture
    output = Moleflow::AsyncOutput.new(config)
    completes_promptly { output.close }
    completes_promptly { output.close }
    expect_raises(Exception, /closed/) { output.consume(Moleflow::Tick.new([] of Moleflow::Chunk, [] of Moleflow::Finished)) }
  end

  it "reports a disk close failure instead of waiting forever" do
    config, _, _ = regression_fixture
    output = Moleflow::AsyncOutput.new(config, CloseFailureOutput.new(config))
    expect_raises(Exception, "injected close failure") { completes_promptly { output.close } }
  end

  it "does not return OK if the final response fails after simulation ends" do
    config, model, sources = regression_fixture
    config.duration_seconds = 0.01
    config.chunk_ms = 20
    setup = Moleflow.pb(Moleflow::D::GetLiveReadsRequest::StreamSetup,
      first_channel: 1_u32, last_channel: 1_u32,
      raw_data_type: Proto::OpenEnum(Moleflow::D::GetLiveReadsRequest::RawDataType).new(3))
    incoming = Channel(Bytes?).new(1)
    incoming.send(Moleflow.pb(Moleflow::D::GetLiveReadsRequest, setup: setup).encode)
    writer = GRPC::RawResponseStream.new(->(_bytes : Bytes) do
      sleep 100.milliseconds
      raise "injected final-send failure"
    end)
    session = Moleflow::LiveSession.new(config, sources, model)
    expect_raises(Exception, "injected final-send failure") do
      completes_promptly { session.run(GRPC::RawRequestStream.new(incoming), GRPC::ServerContext.new("test"), writer) }
    end
  ensure
    incoming.try &.close
  end
end

describe Moleflow::Model do
  it "loads a complete dense table and rejects duplicate kmers" do
    file = File.tempfile("moleflow-model")
    begin
      file.puts("kmer\tmean\nA\t60\nC\t70\nG\t80\nT\t90")
      file.close
      Moleflow::Model.new(file.path).means.should eq([60.0, 70.0, 80.0, 90.0])
      File.open(file.path, "a", &.puts("A\t61"))
      expect_raises(Exception, /duplicate/) { Moleflow::Model.new(file.path) }
    ensure
      File.delete(file.path)
    end
  end

  it "rejects an oversized or odd adapter and accepts the exact byte limit" do
    file = File.tempfile("moleflow-adapter-limit")
    begin
      file.truncate(Moleflow::Model::MAX_ADAPTER_BYTES + 2)
      expect_raises(Exception, /1 MiB/) { Moleflow::Model.new(nil, file.path) }
      file.truncate(3)
      expect_raises(Exception, /Int16/) { Moleflow::Model.new(nil, file.path) }
      file.truncate(Moleflow::Model::MAX_ADAPTER_BYTES)
      Moleflow::Model.new(nil, file.path).prefix.size.should eq(Moleflow::Model::MAX_ADAPTER_BYTES)
    ensure
      file.close
      File.delete(file.path)
    end
  end
end
