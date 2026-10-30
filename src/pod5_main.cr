require "option_parser"
require "./moleflow/formats"

begin
  limit = 1000
  OptionParser.parse do |parser|
    parser.banner = "moleflow-pod5: convert DIRECTORY OUTPUT.pod5 | prepare INPUT.pod5 DIRECTORY [--limit=N]"
    parser.on("--limit=N", "Maximum reads to prepare (default 1000)") { |value| limit = value.to_i }
    parser.on("-h", "--help", "Show help") { puts parser; exit }
  end
  raise "expected command, source and destination; see --help" unless ARGV.size == 3
  case ARGV[0]
  when "convert" then Moleflow::Formats.convert(ARGV[1], ARGV[2])
  when "prepare" then Moleflow::Formats.prepare(ARGV[1], ARGV[2], limit)
  else                raise "unknown command: #{ARGV[0]}"
  end
rescue ex
  STDERR.puts "moleflow-pod5: #{ex.message}"
  exit 1
end
