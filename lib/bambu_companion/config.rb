# frozen_string_literal: true

module BambuCompanion
  class ConfigError < ArgumentError; end

  class Config
    DEFAULTS = {
      "mqttPort" => 8883,
      "ftpsPort" => 990,
      "username" => "bblp",
      "maxSegments" => 500_000
    }.freeze

    attr_reader :host, :mqtt_port, :ftps_port, :serial, :username,
                :max_segments, :mqtt_tls_fingerprint, :ftps_tls_fingerprint

    def self.from_h(raw)
      raise ConfigError, "config must be an object" unless raw.is_a?(Hash)

      values = DEFAULTS.merge(raw.transform_keys(&:to_s))

      new(
        host: values["host"], mqtt_port: values["mqttPort"],
        ftps_port: values["ftpsPort"], serial: values["serial"],
        username: values["username"], max_segments: values["maxSegments"],
        mqtt_tls_fingerprint: values["mqttTlsFingerprint"],
        ftps_tls_fingerprint: values["ftpsTlsFingerprint"]
      )
    rescue ArgumentError, TypeError => error
      raise error if error.is_a?(ConfigError)
      raise ConfigError, error.message
    end

    def initialize(host:, mqtt_port:, ftps_port:, serial:, username:,
                   max_segments:, mqtt_tls_fingerprint: nil,
                   ftps_tls_fingerprint: nil)
      @host = clean_host(host)
      @mqtt_port = bounded_integer(mqtt_port, "mqttPort", 1..65_535)
      @ftps_port = bounded_integer(ftps_port, "ftpsPort", 1..65_535)
      @serial = clean_token(serial, "serial")
      @username = clean_token(username, "username", allow_dots: true)
      @max_segments = bounded_integer(max_segments, "maxSegments", 1_000..1_000_000)
      @mqtt_tls_fingerprint = clean_fingerprint(
        mqtt_tls_fingerprint, "mqttTlsFingerprint"
      )
      @ftps_tls_fingerprint = clean_fingerprint(
        ftps_tls_fingerprint, "ftpsTlsFingerprint"
      )
      freeze
    end

    def trusted_tls?
      !@mqtt_tls_fingerprint.nil? && !@ftps_tls_fingerprint.nil?
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

    def clean_fingerprint(value, name)
      text = value.to_s.strip
      return nil if text.empty?

      valid = text.match?(/\A[0-9A-Fa-f]{64}\z/) ||
              text.match?(/\A(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}\z/)
      raise ConfigError, "#{name} is invalid" unless valid

      text.delete(":").upcase.freeze
    end
  end
end
