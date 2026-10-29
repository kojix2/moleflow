require "./protocol"
require "./engine"

module Moleflow
  # Only the live-session coordinator accesses the partial-chunk map.
  class ResponseEncoder
    STRAND_CLASSIFICATION = 83
    MAX_MESSAGE_BYTES     = 2 * 1024 * 1024
    READ_METADATA_BYTES   = 128
    @partial = {} of Int32 => Chunk

    def initialize(@config : Config)
    end

    def clear : Nil
      @partial.clear
    end

    def discard(channel : Int32) : Nil
      @partial.delete(channel)
    end

    def encode(tick : Tick, now : Int64, setup : D::GetLiveReadsRequest::StreamSetup, dtype : Int32) : Array(D::GetLiveReadsResponse)
      result = [] of D::GetLiveReadsResponse
      current = Moleflow.pb(D::GetLiveReadsResponse, samples_since_start: now.to_u64, seconds_since_start: now / @config.sample_rate)
      accepted = setup.accepted_first_chunk_classifications
      message_bytes = 0
      tick.chunks.each do |original|
        c = original
        read = c.read
        next if read.stopped || read.channel < setup.first_channel || read.channel > setup.last_channel
        next unless accepted.empty? || accepted.includes?(STRAND_CLASSIFICATION)
        if previous = @partial.delete(read.channel)
          if previous.read.id == read.id
            joined = Bytes.new(previous.data.size + c.data.size)
            joined[0, previous.data.size].copy_from(previous.data)
            joined[previous.data.size, c.data.size].copy_from(c.data)
            c = Chunk.new(read, previous.from, joined)
          end
        end
        if c.data.size // 2 < setup.sample_minimum_chunk_size
          @partial[read.channel] = c
          next
        end
        data = c.data
        if dtype == 1
          data = Bytes.empty
        elsif dtype == 2
          data = Bytes.new(c.data.size * 2)
          (c.data.size // 2).times do |i|
            raw = IO::ByteFormat::LittleEndian.decode(Int16, c.data[i*2, 2])
            value = ((raw + @config.offset) * @config.scale).to_f32
            IO::ByteFormat::LittleEndian.encode(value, data[i*4, 4])
          end
        end
        if current.channels.has_key?(read.channel.to_u32) || message_bytes + data.size > MAX_MESSAGE_BYTES
          result << current
          message_bytes = 0
          current = Moleflow.pb(D::GetLiveReadsResponse, samples_since_start: now.to_u64, seconds_since_start: now / @config.sample_rate)
        end
        current.channels[read.channel.to_u32] = Moleflow.pb(D::GetLiveReadsResponse::ReadData,
          id: read.id,
          start_sample: read.start.to_u64,
          chunk_start_sample: (read.start + c.from).to_u64,
          chunk_length: (c.data.size // 2).to_u64,
          chunk_classifications: [STRAND_CLASSIFICATION],
          raw_data: data,
          median_before: 100_f32,
          median: 100_f32)
        message_bytes += data.size + READ_METADATA_BYTES
        if current.channels.size >= @config.max_batch_channels
          result << current
          message_bytes = 0
          current = Moleflow.pb(D::GetLiveReadsResponse, samples_since_start: now.to_u64, seconds_since_start: now / @config.sample_rate)
        end
      end
      tick.finished.each do |finished|
        if pending = @partial[finished.read.channel]?
          @partial.delete(finished.read.channel) if pending.read.id == finished.read.id
        end
      end
      result << current unless current.channels.empty?
      result
    end
  end
end
