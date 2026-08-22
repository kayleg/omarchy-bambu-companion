# frozen_string_literal: true

require "json"
require "mqtt"
require "openssl"
require_relative "tls_certificate"

module BambuCompanion
  class MqttSession
    MAX_BACKOFF = 30.0
    MAX_REPORT_BYTES = 1 << 20

    def self.backoff(failure_index)
      [2**Integer(failure_index), MAX_BACKOFF].min.to_f
    end

    def self.authentication_error?(error)
      return false unless error.is_a?(MQTT::ProtocolException)

      message = error.message.to_s.downcase
      message.include?("bad user name or password") || message.include?("not authorised")
    end

    def initialize(config:, secret:, on_report:, on_connection:, on_error:,
                   client_factory: nil, jitter: -> { rand * 0.25 })
      @config = config
      @secret = String(secret)
      @on_report = on_report
      @on_connection = on_connection
      @on_error = on_error
      @client_factory = client_factory || method(:build_client)
      @jitter = jitter
      @stop_mutex = Mutex.new
      @stop_cv = ConditionVariable.new
      @stopped = false
      @client = nil
      @reader_thread = nil
      @runner_thread = nil
    end

    def run
      can_run = @stop_mutex.synchronize do
        unless @stopped
          @runner_thread = Thread.current
          true
        end
      end
      return unless can_run

      failures = 0
      until stopped?
        connected = false
        begin
          connect_once { connected = true }
          failures = 0
        # mqtt 0.7 deliberately inherits MQTT::Exception from Exception rather
        # than StandardError. Catch that library family explicitly so a CONNACK
        # authentication refusal cannot terminate the daemon control channel.
        rescue MQTT::Exception, StandardError => error
          break if stopped?

          failures = 0 if connected
          @on_connection.call(false, error)
          @on_error.call(error)
          break if error.is_a?(TlsCertificateError)

          wait(self.class.backoff(failures) + @jitter.call)
          failures += 1
        end
      end
    ensure
      @stop_mutex.synchronize do
        @runner_thread = nil if @runner_thread.equal?(Thread.current)
      end
    end

    def connect_once
      client = @client_factory.call(@config, @secret)
      should_connect = @stop_mutex.synchronize do
        unless @stopped
          @client = client
          true
        end
      end
      return unless should_connect

      client.connect
      yield if block_given?
      client.subscribe(report_topic)
      client.publish(request_topic, JSON.generate(pushall), false, 0)
      client.publish(request_topic, JSON.generate(get_version), false, 0)
      @on_connection.call(true, nil)
      start_reader = Queue.new
      reader = Thread.new do
        start_reader.pop
        client.get do |_topic, payload|
          parsed = parse_report(payload)
          @on_report.call(parsed) if parsed.is_a?(Hash)
        rescue JSON::ParserError => error
          @on_error.call(error)
        end
      end
      reader.report_on_exception = false
      reader_started = @stop_mutex.synchronize do
        unless @stopped
          @reader_thread = reader
          true
        end
      end
      return unless reader_started

      start_reader << true
      reader.value
    rescue OpenSSL::SSL::SSLError => error
      TlsCertificate.raise_if_pin_rejected!(client.ssl_context, error)
    ensure
      prior_error = $!
      begin
        reader&.kill
        client&.disconnect(false)
      rescue MQTT::Exception, StandardError
        raise if prior_error.nil?
      ensure
        @stop_mutex.synchronize do
          @client = nil if @client.equal?(client)
          @reader_thread = nil if @reader_thread.equal?(reader)
        end
      end
    end

    def stop
      client = nil
      reader = nil
      runner = nil
      @stop_mutex.synchronize do
        @stopped = true
        client = @client
        reader = @reader_thread
        runner = @runner_thread
        @stop_cv.broadcast
      end
      reader&.kill
      runner&.kill unless runner.nil? || runner.equal?(Thread.current)
      client&.disconnect(false)
    rescue MQTT::Exception, StandardError
      nil
    end

    private

    def stopped? = @stop_mutex.synchronize { @stopped }

    def wait(seconds)
      @stop_mutex.synchronize { @stop_cv.wait(@stop_mutex, seconds) unless @stopped }
    end

    def report_topic = "device/#{@config.serial}/report"
    def request_topic = "device/#{@config.serial}/request"
    def pushall = { "pushing" => { "sequence_id" => "0", "command" => "pushall" } }
    def get_version = { "info" => { "sequence_id" => "1", "command" => "get_version" } }

    def parse_report(payload)
      payload = String(payload)
      if payload.bytesize > MAX_REPORT_BYTES
        raise JSON::ParserError, "MQTT report exceeds #{MAX_REPORT_BYTES} bytes"
      end

      JSON.parse(payload)
    end

    def build_client(config, secret)
      MQTT::Client.new(
        host: config.host, port: config.mqtt_port, ssl: true,
        verify_host: false, connect_timeout: 8, ack_timeout: 5,
        keep_alive: 15, clean_session: true,
        client_id: MQTT::Client.generate_client_id("bambu-companion-", 8),
        username: config.username, password: secret
      ).tap do |client|
        TlsCertificate.configure_pinned_context(
          client.ssl_context, config.mqtt_tls_fingerprint
        )
      end
    end
  end
end
