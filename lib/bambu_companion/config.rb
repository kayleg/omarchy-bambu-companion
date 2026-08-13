# frozen_string_literal: true

module BambuCompanion
  class ConfigError < ArgumentError; end

  class Config
    DEFAULTS = {
      "mqttPort" => 8883,
      "ftpsPort" => 990,
      "username" => "bblp",
      "maxSegments" => 40_000
    }.freeze

    attr_reader :host, :mqtt_port, :ftps_port, :serial, :username,
                :max_segments

    def self.from_h(raw)
      raise ConfigError, "config must be an object" unless raw.is_a?(Hash)

      values = DEFAULTS.merge(raw.transform_keys(&:to_s))

      new(
        host: values["host"], mqtt_port: values["mqttPort"],
        ftps_port: values["ftpsPort"], serial: values["serial"],
        username: values["username"], max_segments: values["maxSegments"]
      )
    rescue ArgumentError, TypeError => error
      raise error if error.is_a?(ConfigError)
      raise ConfigError, error.message
    end

    def initialize(host:, mqtt_port:, ftps_port:, serial:, username:,
                   max_segments:)
      @host = clean_host(host)
      @mqtt_port = bounded_integer(mqtt_port, "mqttPort", 1..65_535)
      @ftps_port = bounded_integer(ftps_port, "ftpsPort", 1..65_535)
      @serial = clean_token(serial, "serial")
      @username = clean_token(username, "username", allow_dots: true)
      @max_segments = bounded_integer(max_segments, "maxSegments", 1_000..100_000)
      freeze
    end

    private

    def clean_host(value)
      text = value.to_s.strip

      invalid = text.empty? || text.bytesize > 255 || text.match?(/[[:cntrl:]]/)
      raise ConfigError, "host is invalid" if invalid
      text
    end

    def clean_token(value, name, allow_dots: false)
      text = value.to_s.strip

      pattern = allow_dots ? /\A[A-Za-z0-9_.:-]+\z/ : /\A[A-Za-z0-9_-]+\z/
      invalid = text.empty? || text.bytesize > 128 || !pattern.match?(text)
      raise ConfigError, "#{name} is invalid" if invalid
      text
    end

    def bounded_integer(value, name, range)
      number = Integer(value)
      raise ConfigError, "#{name} is outside #{range}" unless range.cover?(number)
      number
    end
  end
end
