require "./live_session"

module Moleflow
  class Api < GRPC::Service
    getter service_full_name : String
    getter busy : Bool = false
    @used = false

    def initialize(@kind : String, @config : Config, @sources : Array(Source), @model : Model)
      @service_full_name = "minknow_api.#{@kind}.#{@kind.split('_').map(&.capitalize).join}Service"
    end

    def encode(message) : {Bytes, GRPC::Status}
      {message.encode, GRPC::Status.ok}
    end

    def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
      case {@kind, method}
      when {"data", "get_data_types"}
        encode(Moleflow.pb(D::GetDataTypesResponse,
          uncalibrated_signal: Moleflow.pb(D::GetDataTypesResponse::DataType,
            size: 2_u32),
          calibrated_signal: Moleflow.pb(D::GetDataTypesResponse::DataType,
            type_: Proto::OpenEnum(D::GetDataTypesResponse::DataType::Type).new(2),
            size: 4_u32)))
      when {"device", "get_flow_cell_info"}
        encode(Moleflow.pb(MinknowApi::Device::GetFlowCellInfoResponse,
          has_flow_cell: true,
          channel_count: @config.channels.to_u32,
          wells_per_channel: 4_u32,
          flow_cell_id: "MOLEFLOW",
          product_code: "FLO-MIN114"))
      when {"device", "get_sample_rate"}
        encode(Moleflow.pb(MinknowApi::Device::GetSampleRateResponse, sample_rate: @config.sample_rate.to_u32))
      when {"device", "get_calibration"}
        req = MinknowApi::Device::GetCalibrationRequest.decode(request_body)
        validate_channels(req.first_channel, req.last_channel)
        n = (req.last_channel - req.first_channel + 1).to_i
        encode(Moleflow.pb(MinknowApi::Device::GetCalibrationResponse,
          digitisation: 2048_u32,
          offsets: Array.new(n,
            @config.offset.to_f32),
          pa_ranges: Array.new(n,
            (@config.scale * 2048).to_f32),
          has_calibration: true))
      when {"instance", "get_version_info"}
        v = Moleflow.pb(MinknowApi::Instance::GetVersionInfoResponse::MinknowVersion, major: 6, minor: 1, patch: 4, full: "6.1.4")
        encode(Moleflow.pb(MinknowApi::Instance::GetVersionInfoResponse, minknow: v, distribution_version: "moleflow-#{VERSION}"))
      when {"analysis_configuration", "get_read_classifications"}
        encode(Moleflow.pb(MinknowApi::AnalysisConfiguration::GetReadClassificationsResponse,
          read_classifications: {65 => "adapter",
                                 83 => "strand",
                                 80 => "pore",
                                 90 => "zero"}))
      when {"analysis_configuration", "get_analysis_configuration"}
        encode(Moleflow.pb(MinknowApi::AnalysisConfiguration::AnalysisConfiguration,
          event_detection: Moleflow.pb(MinknowApi::AnalysisConfiguration::EventDetection,
            window_size: 0_u32)))
      when {"acquisition", "current_status"}
        encode(Moleflow.pb(MinknowApi::Acquisition::CurrentStatusResponse, status: Proto::OpenEnum(MinknowApi::Acquisition::MinknowStatus).new(3)))
      when {"acquisition", "get_current_acquisition_run"}, {"acquisition", "get_acquisition_info"}
        encode(Moleflow.pb(MinknowApi::Acquisition::AcquisitionRunInfo, run_id: "moleflow-#{@config.seed}"))
      when {"protocol", "get_current_protocol_run"}, {"protocol", "get_run_info"}
        encode(Moleflow.pb(MinknowApi::Protocol::ProtocolRunInfo, run_id: "moleflow-#{@config.seed}", output_path: File.expand_path(@config.output || ".")))
      when {"log", "send_user_message"}
        {Bytes.empty, GRPC::Status.ok}
      else
        {Bytes.empty, GRPC::Status.unimplemented("#{service_full_name}/#{method}")}
      end
    end

    def validate_channels(first : UInt32, last : UInt32)
      ProtocolValidation.channels!(first, last, @config.channels)
    end

    def server_streaming?(method : String) : Bool
      @kind == "manager" && method == "flow_cell_positions"
    end

    def dispatch_server_stream(method : String, body : Bytes, ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
      pos = Moleflow.pb(MinknowApi::Manager::FlowCellPosition,
        name: @config.device_id,
        state: Proto::OpenEnum(MinknowApi::Manager::FlowCellPosition::State).new(1),
        rpc_ports: Moleflow.pb(MinknowApi::Manager::FlowCellPosition::RpcPorts,
          secure: @config.position_port.to_u32))
      writer.send_raw(Moleflow.pb(MinknowApi::Manager::FlowCellPositionsResponse, total_count: 1, positions: [pos]).encode)
      GRPC::Status.ok
    end

    def bidi_streaming?(method : String) : Bool
      @kind == "data" && method == "get_live_reads"
    end

    def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
      if @busy || @used
        raise GRPC::StatusError.new(GRPC::StatusCode::RESOURCE_EXHAUSTED,
          "one live-read session per server run; restart to reset")
      end
      @busy = true
      @used = true
      begin
        LiveSession.new(@config, @sources, @model).run(requests, ctx, writer)
      ensure
        @busy = false
      end
    end
  end
end
