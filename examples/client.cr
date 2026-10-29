# Small Crystal client: receive signal, unblock the first read, verify its ack.
require "../src/moleflow/api"

channel = GRPC::Channel.new(ARGV[0]? || "localhost:10001")
call = channel.open_bidi_stream_live("minknow_api.data.DataService", "get_live_reads", GRPC::ClientContext.new)
setup = Moleflow.pb(Moleflow::D::GetLiveReadsRequest::StreamSetup,
  first_channel: 1_u32, last_channel: 32_u32,
  raw_data_type: Proto::OpenEnum(Moleflow::D::GetLiveReadsRequest::RawDataType).new(3))
call.send_raw(Moleflow.pb(Moleflow::D::GetLiveReadsRequest, setup: setup).encode)
sent = false
samples = 0_u64
begin
  call.each do |bytes|
    response = Moleflow::D::GetLiveReadsResponse.decode(bytes)
    response.action_responses.each { |ack| puts "#{ack.action_id}: #{ack.response}" }
    response.channels.each do |number, read|
      samples += read.chunk_length
      unless sent
        action = Moleflow.pb(Moleflow::D::GetLiveReadsRequest::Action,
          channel: number, id: read.id, action_id: "first-read",
          unblock: Moleflow.pb(Moleflow::D::GetLiveReadsRequest::UnblockAction, duration: 0.1))
        actions = Moleflow.pb(Moleflow::D::GetLiveReadsRequest::Actions, actions: [action])
        call.send_raw(Moleflow.pb(Moleflow::D::GetLiveReadsRequest, actions: actions).encode)
        sent = true
      end
    end
  end
  puts "Received #{samples} samples; status=#{call.status}"
ensure
  call.cancel
  channel.close
end
