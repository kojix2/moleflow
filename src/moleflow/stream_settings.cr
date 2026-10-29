require "./protocol"

module Moleflow
  module ProtocolValidation
    def self.channels!(first : UInt32, last : UInt32, count : Int32) : Nil
      unless first >= 1 && last >= first && last <= count
        raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "invalid channel range")
      end
    end
  end

  module StreamSettings
    def self.validate(setup : D::GetLiveReadsRequest::StreamSetup, previous : Int32, config : Config) : {Int32, Int64}
      ProtocolValidation.channels!(setup.first_channel, setup.last_channel, config.channels)
      dtype = setup.raw_data_type.value
      dtype = previous if dtype == 0
      raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "invalid raw_data_type") unless (1..3).includes?(dtype)
      raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "sample_minimum_chunk_size exceeds max_chunk_samples") if setup.sample_minimum_chunk_size > config.max_chunk_samples
      max_samples = Int64::MAX
      if setup.max_unblock_read_length_samples > 0
        raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "unblock limit overflow") if setup.max_unblock_read_length_samples > Int64::MAX
        max_samples = setup.max_unblock_read_length_samples.to_i64
      elsif setup.max_unblock_read_length_seconds != 0
        value = setup.max_unblock_read_length_seconds
        raise GRPC::StatusError.new(GRPC::StatusCode::INVALID_ARGUMENT, "invalid unblock limit") unless value.finite? && value > 0 && value < Int64::MAX / config.sample_rate
        max_samples = (value * config.sample_rate).to_i64
      end
      {dtype, max_samples}
    end
  end
end
