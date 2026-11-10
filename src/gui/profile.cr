require "../moleflow/config"
require "./model"
require "./i18n"

module NanoporeGUI
  module Profile
    def self.title : String
      "Moleflow"
    end

    def self.command : String
      "moleflow"
    end

    def self.version : String
      Moleflow::VERSION
    end

    def self.modes : Array(String)
      ["Serve MinKNOW simulation", "Generate signals offline"]
    end

    def self.replay? : Bool
      false
    end

    def self.fields : Array(Field)
      [
        Field.new("samples.0.path", "Primary input (FASTA / raw int16)", picker: :open),
        Field.new("channels", "Channels", :integer),
        Field.new("workers", "Workers", :integer),
        Field.new("duration_seconds", "Duration (seconds)", :number),
        Field.new("model", "Pore model (optional)", :optional, :open),
        Field.new("adapter_signal", "Adapter signal (optional)", :optional, :open),
        Field.new("output", "Output directory (new path, optional)", :optional, :save),
        Field.new("host", "Listen address"),
        Field.new("manager_port", "Manager port", :integer),
        Field.new("position_port", "Position port", :integer),
      ]
    end

    def self.initial : Document
      parse(%({"samples":[{"path":"examples/reference.fa","circular":true}],"model":"models/r10_dna.tsv","adapter_signal":"models/adapter.i16"}))
    end

    def self.parse(text : String) : Document
      config = Moleflow::Config.from_json(text)
      raise NanoporeGUI.t("At least one sample is required; edit samples in JSON") if config.samples.empty?
      defaults = JSON.parse(config.to_json).as_h
      defaults.merge!(JSON.parse(text).as_h)
      Document.new(defaults.to_json)
    end

    def self.arguments(action : Symbol, mode : Int32, replay : String) : Array(String)
      return ["--validate"] if action == :validate
      mode == 1 ? ["--simulate"] : [] of String
    end
  end
end
