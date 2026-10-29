module Moleflow
  module Noise
    def self.mix(x : UInt64) : UInt64
      x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9_u64
      x = (x ^ (x >> 27)) &* 0x94d049bb133111eb_u64
      x ^ (x >> 31)
    end

    def self.uniform(seed : UInt64, index : UInt64) : Float64
      ((mix(seed &+ (index &* 0x9e3779b97f4a7c15_u64)) >> 11).to_f + 0.5) / 9007199254740992.0
    end

    def self.normal(seed : UInt64, index : UInt64) : Float64
      Math.sqrt(-2.0 * Math.log(uniform(seed, index &* 2))) * Math.cos(2.0 * Math::PI * uniform(seed, index &* 2 &+ 1))
    end
  end
end
