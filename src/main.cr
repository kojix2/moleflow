require "option_parser"
require "./moleflow/application"

begin
  config_path = "examples/demo.json"
  mode = "serve"
  OptionParser.parse do |parser|
    parser.banner = "moleflow #{Moleflow::VERSION}: MinKNOW-compatible research simulator"
    parser.on("-c PATH", "--config=PATH", "JSON configuration") { |v| config_path = v }
    parser.on("--simulate", "Run deterministic offline simulation") { mode = "simulate" }
    parser.on("--validate", "Validate configuration, references and model") { mode = "validate" }
    parser.on("-h", "--help", "Show help") { puts parser; exit }
    parser.on("--version", "Show version") { puts Moleflow::VERSION; exit }
  end
  config = Moleflow::Config.from_json(File.read(config_path))
  config.validate!
  model = Moleflow::Model.new(config.model, config.adapter_signal)
  sources = Moleflow::Source.load(config, model)
  STDERR.puts "WARNING: toy current model; use a calibrated kmer model or real signal replay for basecalling experiments" if model.toy && sources.any? { |s| !s.replay }
  app = Moleflow::Application.new(config, sources, model)
  case mode
  when "validate"
    puts "OK: #{sources.size} sources, #{config.channels} channels, #{config.workers} workers"
  when "simulate"
    app.simulate
  else
    app.serve
  end
rescue ex
  STDERR.puts "moleflow: #{ex.message}"
  exit 1
end
