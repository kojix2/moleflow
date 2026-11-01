require "spec"
require "../../src/gui/profile"

module NanoporeGUI
  describe Profile do
    it "retains every sample, replay settings and fields outside the form" do
      input = %({"samples":[{"path":"raw.i16","replay":true,"weight":2},{"path":"two.fa"}],"seed":999,"max_chunk_samples":90000})
      document = Profile.parse(input)
      document.get("samples.0.replay").as_bool.should be_true
      document.get("samples.0.weight").as_i.should eq(2)
      document.get("samples.1.path").as_s.should eq("two.fa")
      document.get("seed").as_i.should eq(999)
      document.get("max_chunk_samples").as_i.should eq(90000)
      document.get("host").as_s.should eq("127.0.0.1")
    end

    it "requires a sample for the primary input form" do
      expect_raises(Exception, /sample/) { Profile.parse(%({"samples":[]})) }
    end

    it "uses separate serve, simulate and validate CLI modes" do
      Profile.arguments(:validate, 0, "").should eq(["--validate"])
      Profile.arguments(:run, 0, "").should be_empty
      Profile.arguments(:run, 1, "").should eq(["--simulate"])
    end
  end
end
