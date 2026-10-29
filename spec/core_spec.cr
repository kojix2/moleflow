require "spec"
require "../src/moleflow/output"
require "../src/moleflow/worker_pool"

def fixture(workers = 1)
  c = Moleflow::Config.from_json(%({"samples":[{"path":"examples/reference.fa","circular":true}],"channels":8,"workers":#{workers},"sample_rate":4000,"chunk_ms":100}))
  m = Moleflow::Model.new(nil)
  {c, m, Moleflow::Source.load(c, m)}
end

describe Moleflow::Engine do
  it "generates identical signal regardless of chunk boundaries" do
    c, m, sources = fixture
    e = Moleflow::Engine.new(c, sources, m, [1])
    e.tick(0)
    r = (e.pores[0].read || raise "expected active read")
    whole = r.signal(0_i64, 1000, c, m)
    a = r.signal(0_i64, 333, c, m)
    b = r.signal(333_i64, 667, c, m)
    whole.to_a.should eq(a.to_a + b.to_a)
  end
  it "rejects stale actions and acknowledges unblock exactly once" do
    c, m, sources = fixture
    e = Moleflow::Engine.new(c, sources, m, [1])
    e.tick(0)
    id = (e.pores[0].read || raise "expected active read").id
    e.action(Moleflow::Action.new(1, "stale", true), 100_i64).should eq(1)
    e.action(Moleflow::Action.new(1, id, true), 100_i64).should eq(0)
    e.action(Moleflow::Action.new(1, id, true), 100_i64).should eq(1)
    e.tick(100).finished[0].samples.should eq(100)
  end
  it "stop further data retains sequencing and max-unblock length is enforced" do
    c, m, sources = fixture
    e = Moleflow::Engine.new(c, sources, m, [1])
    e.tick(0)
    r = (e.pores[0].read || raise "expected active read")
    e.action(Moleflow::Action.new(1, r.id, true, max_samples: 50_i64), 100_i64).should eq(2)
    e.action(Moleflow::Action.new(1, r.id, false), 100_i64).should eq(0)
    r.stopped.should be_true
    e.tick(200).chunks.should be_empty
    r.cursor.should eq(200)
  end
  it "rejects excessive lag rather than generating unbounded buffers" do
    c, m, sources = fixture
    c.max_chunk_samples = 100
    e = Moleflow::Engine.new(c, sources, m, [1])
    e.tick(0)
    expect_raises(Exception, /fell behind/) { e.tick(1000) }
  end
  it "has independent random sequences for each molecule" do
    c, m, sources = fixture
    a = Moleflow::Molecule.new(1, 1_u64, sources[0], 0, false, 1000_i64, 0_i64, 1_u64)
    b = Moleflow::Molecule.new(1, 2_u64, sources[0], 0, false, 1000_i64, 0_i64, 2_u64)
    a.signal(0_i64, 100, c, m).should_not eq(b.signal(0_i64, 100, c, m))
  end
  it "matches signal and IDs with one and four workers" do
    signatures = [1, 4].map do |workers|
      c, m, sources = fixture(workers)
      pool = Moleflow::Pool.new(c, sources, m)
      begin
        pool.tick(0)
        pool.tick(400).chunks.sort_by!(&.read.channel).map { |ch| {ch.read.id, ch.data.to_a} }
      ensure
        pool.close
      end
    end
    signatures[0].should eq(signatures[1])
  end
  it "replays little-endian bytes without changing the recorded signal" do
    path = File.tempfile("moleflow-replay")
    begin
      path.write(Bytes[1, 0, 255, 255, 0, 128]); path.close
      source = Moleflow::Source.new("replay", path.path, Bytes.empty, 3_i64, 1.0, false, true)
      c, m, _ = fixture
      read = Moleflow::Molecule.new(1, 1_u64, source, 0, false, 3_i64, 0_i64, 1_u64)
      read.signal(1_i64, 2, c, m).should eq(Bytes[255, 255, 0, 128])
    ensure
      File.delete(path.path)
    end
  end
  it "validates settings and complete current models" do
    c, _, _ = fixture
    c.channels = 0
    expect_raises(Exception) { c.validate! }
    f = File.tempfile("moleflow-model")
    begin
      f.puts("A\t60"); f.close
      expect_raises(Exception, /incomplete/) { Moleflow::Model.new(f.path) }
    ensure
      File.delete(f.path)
    end
  end
end

describe "signal boundaries" do
  it "preserves adapter bytes and supports a chunk crossing the adapter boundary" do
    c, _, sources = fixture
    f = File.tempfile("moleflow-adapter")
    begin
      f.write(Bytes[1, 0, 255, 255]); f.close
      m = Moleflow::Model.new(nil, f.path)
      r = Moleflow::Molecule.new(1, 1_u64, sources[0], 0, false, 100_i64, 0_i64, 1_u64)
      r.signal(0_i64, 4, c, m)[0, 4].should eq(Bytes[1, 0, 255, 255])
      r.signal(0_i64, 4, c, m).to_a.should eq(r.signal(0_i64, 1, c, m).to_a + r.signal(1_i64, 3, c, m).to_a)
    ensure
      File.delete(f.path)
    end
  end
  it "wraps reverse circular molecules without changing output with chunk boundaries" do
    c, m, _ = fixture
    c.noise_pa = 0
    s = Moleflow::Source.new("circle", "", "ACGT".to_slice, 0_i64, 1.0, true, false)
    r = Moleflow::Molecule.new(1, 1_u64, s, 0, true, 1000_i64, 0_i64, 1_u64)
    whole = r.signal(0_i64, 100, c, m)
    whole.to_a.should eq(r.signal(0_i64, 37, c, m).to_a + r.signal(37_i64, 63, c, m).to_a)
  end
  it "handles many short reads within one delivery tick" do
    c, m, sources = fixture
    c.mean_read_length = 1
    c.read_length_sigma = 0
    c.reacquire_seconds = 0
    e = Moleflow::Engine.new(c, sources, m, [1])
    tick = e.tick(100)
    tick.chunks.sum { |x| x.data.size // 2 }.should eq(100)
    tick.finished.size.should eq(10)
    tick.finished.map(&.read.id).uniq!.size.should eq(10)
  end
end
