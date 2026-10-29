require "json"

module Moleflow
  VERSION = "0.1.2"

  class SampleConfig
    include JSON::Serializable
    property path : String
    property weight : Float64 = 1.0
    property circular : Bool = false
    property replay : Bool = false
  end

  class Config
    include JSON::Serializable
    property samples : Array(SampleConfig) = [] of SampleConfig
    property channels : Int32 = 512
    property workers : Int32 = 4
    property sample_rate : Int32 = 5000
    property sequencing_speed : Float64 = 400.0
    property chunk_ms : Int32 = 400
    property duration_seconds : Float64 = 60.0
    property seed : UInt64 = 12345_u64
    property mean_read_length : Float64 = 10000.0
    property read_length_sigma : Float64 = 0.5
    property max_read_bases : Int32 = 1000000
    property working_fraction : Float64 = 1.0
    property death_probability : Float64 = 0.0
    property reacquire_seconds : Float64 = 0.2
    property noise_pa : Float64 = 1.0
    property scale : Float64 = 0.1462070643901825
    property offset : Float64 = -243.0
    property model : String? = nil
    property adapter_signal : String? = nil
    property output : String? = nil
    property max_reference_bytes : Int64 = 4000000000_i64
    property max_chunk_samples : Int32 = 50000
    property max_batch_channels : Int32 = 24
    property stream_queue : Int32 = 32
    property host : String = "127.0.0.1"
    property manager_port : Int32 = 9502
    property position_port : Int32 = 10001
    property device_id : String = "MOLEFLOW"
    property tls_cert : String? = nil
    property tls_key : String? = nil

    def validate!
      validate_inputs!
      validate_distribution!
      validate_resources!
      validate_samples!
    end

    private def validate_inputs!
      raise "samples must not be empty" if samples.empty?
      raise "channels must be 1..65535" unless (1..65535).includes?(channels)
      raise "workers must be 1..64" unless (1..64).includes?(workers)
      raise "invalid rates" unless sample_rate > 0 && sequencing_speed.finite? && sequencing_speed > 0
    end

    private def validate_distribution!
      raise "invalid timing" unless chunk_ms > 0 && duration_seconds.finite? && duration_seconds > 0
      duration_samples = duration_seconds * sample_rate
      raise "duration exceeds sample time range" unless duration_samples.finite? && duration_samples < Int64::MAX
      raise "chunk exceeds max_chunk_samples" if chunk_ms.to_i64 * sample_rate // 1000 > max_chunk_samples
      raise "invalid read distribution" unless mean_read_length.finite? && mean_read_length > 0 && read_length_sigma.finite? && (0.0..10.0).includes?(read_length_sigma) && max_read_bases > 0
      raise "invalid probabilities" unless (0.0..1.0).includes?(working_fraction) && (0.0..1.0).includes?(death_probability)
    end

    private def validate_resources!
      raise "invalid noise/calibration" unless noise_pa.finite? && noise_pa >= 0 && scale.finite? && scale > 0 && offset.finite?
      raise "invalid reacquisition" unless reacquire_seconds.finite? && reacquire_seconds >= 0
      raise "invalid bounds" unless max_reference_bytes > 0 && (1..250000).includes?(max_chunk_samples) && (1..128).includes?(max_batch_channels) && (1..256).includes?(stream_queue)
      raise "output path must not be empty" if output.try(&.strip.empty?)
      raise "TLS requires certificate and key" unless tls_cert.nil? == tls_key.nil?
    end

    private def validate_samples!
      raise "sample weights overflow" unless samples.sum(&.weight).finite?
      raise "invalid ports" unless (1..65535).includes?(manager_port) && (1..65535).includes?(position_port) && manager_port != position_port
      samples.each { |s| raise "sample weight must be finite and positive" unless s.weight.finite? && s.weight > 0 }
    end
  end
end
