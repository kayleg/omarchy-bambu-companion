# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "openssl"
require "timeout"
require "bambu_companion/config"
require "bambu_companion/mqtt_session"

class MqttSessionTest < Minitest::Test
  class FakeClient
    attr_reader :subscriptions, :publications

    def initialize(report)
      @report = report
      @subscriptions = []
      @publications = []
    end

    def connect = true
    def subscribe(topic) = @subscriptions << topic
    def publish(topic, payload, retain = false, qos = 0) = @publications << [topic, payload, retain, qos]

    def get
      yield("report", JSON.generate(@report))
      raise IOError, "connection closed"
    end

    def disconnect(*) = true
  end

  class PayloadClient < FakeClient
    def initialize(*payloads)
      super({})
      @payloads = payloads
    end

    def get
      @payloads.each { |payload| yield("report", payload) }
      raise IOError, "connection closed"
    end
  end

  class FailingClient < FakeClient
    def initialize(error)
      super({})
      @error = error
    end

    def connect = raise @error
  end

  class BlockingClient < FakeClient
    def initialize
      super({})
      @entered_get = Queue.new
      @messages = Queue.new
    end

    def get
      @entered_get << true
      loop { yield("report", @messages.pop) }
    end

    def wait_until_get = @entered_get.pop
    def deliver(payload) = @messages << payload
  end

  class ConnectTrackingClient < FakeClient
    attr_reader :connect_calls

    def initialize
      super({})
      @connect_calls = 0
    end

    def connect
      @connect_calls += 1
      true
    end
  end

  class BlockingConnectClient < FakeClient
    def initialize
      super({})
      @entered_connect = Queue.new
      @release_connect = Queue.new
    end

    def connect
      @entered_connect << true
      @release_connect.pop
    end

    def wait_until_connect = @entered_connect.pop
    def release_connect = @release_connect << true
  end

  class DisconnectFailingClient < FakeClient
    def disconnect(*) = raise RuntimeError, "disconnect failed"
  end

  def test_connect_subscribe_pushall_and_report_callback
    config = config_fixture
    client = FakeClient.new("print" => { "mc_percent" => 7 })
    reports = []
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret",
      on_report: ->(report) { reports << report },
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: ->(*) { client }
    )

    assert_raises(IOError) { session.connect_once }
    assert_equal ["device/0309C123456789/report"], client.subscriptions
    topic, payload, retain, qos = client.publications.fetch(0)
    assert_equal "device/0309C123456789/request", topic
    assert_equal({ "pushing" => { "sequence_id" => "0", "command" => "pushall" } }, JSON.parse(payload))
    refute retain
    assert_equal 0, qos
    version_topic, version_payload, version_retain, version_qos = client.publications.fetch(1)
    assert_equal "device/0309C123456789/request", version_topic
    assert_equal({ "info" => { "sequence_id" => "1", "command" => "get_version" } },
                 JSON.parse(version_payload))
    refute version_retain
    assert_equal 0, version_qos
    assert_equal 7, reports.dig(0, "print", "mc_percent")
  end

  def test_backoff_is_bounded_and_stop_wakes_waiter
    assert_equal([1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0],
                 7.times.map { |index| BambuCompanion::MqttSession.backoff(index) })
  end

  def test_invalid_json_reports_error_and_keeps_consuming_messages
    config = config_fixture
    client = PayloadClient.new("not json", JSON.generate("print" => { "mc_percent" => 8 }))
    reports = []
    errors = []
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret",
      on_report: ->(report) { reports << report },
      on_connection: ->(*) {}, on_error: ->(error) { errors << error },
      client_factory: ->(*) { client }
    )

    assert_raises(IOError) { session.connect_once }
    assert_instance_of JSON::ParserError, errors.fetch(0)
    assert_equal 8, reports.dig(0, "print", "mc_percent")
  end

  def test_oversized_report_is_not_parsed_and_later_reports_still_arrive
    config = config_fixture
    oversized = "x" * (BambuCompanion::MqttSession::MAX_REPORT_BYTES + 1)
    client = PayloadClient.new(oversized, JSON.generate("print" => { "mc_percent" => 9 }))
    reports = []
    errors = []
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret",
      on_report: ->(report) { reports << report },
      on_connection: ->(*) {}, on_error: ->(error) { errors << error },
      client_factory: ->(*) { client }
    )

    assert_raises(IOError) { session.connect_once }
    assert_instance_of JSON::ParserError, errors.fetch(0)
    assert_equal 9, reports.dig(0, "print", "mc_percent")
  end

  def test_run_reports_connection_failure_and_can_stop_during_backoff
    config = config_fixture
    failure = IOError.new("printer unavailable")
    connections = []
    errors = []
    session = nil
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(connected, error) { connections << [connected, error] },
      on_error: lambda { |error|
        errors << error
        session.stop
      },
      client_factory: ->(*) { FailingClient.new(failure) }, jitter: -> { 0.0 }
    )

    session.run

    assert_equal [[false, failure]], connections
    assert_equal [failure], errors
  end

  def test_run_catches_mqtt_protocol_authentication_rejection
    config = config_fixture
    failure = MQTT::ProtocolException.new("Connection refused: not authorised")
    connections = []
    errors = []
    session = nil
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(connected, error) { connections << [connected, error] },
      on_error: lambda { |error|
        errors << error
        session.stop
      },
      client_factory: ->(*) { FailingClient.new(failure) }, jitter: -> { 0.0 }
    )

    session.run

    assert_equal [[false, failure]], connections
    assert_equal [failure], errors
  end

  def test_authentication_error_only_classifies_mqtt_credential_refusals
    klass = BambuCompanion::MqttSession

    assert klass.authentication_error?(
      MQTT::ProtocolException.new("Connection refused: bad user name or password")
    )
    assert klass.authentication_error?(
      MQTT::ProtocolException.new("Connection refused: not authorised")
    )
    refute klass.authentication_error?(MQTT::ProtocolException.new("No Ping Response"))
    refute klass.authentication_error?(IOError.new("not authorised"))
  end

  def test_backoff_resets_after_a_connection_succeeds
    config = config_fixture
    clients = [FailingClient.new(IOError.new("offline")), FakeClient.new("print" => {})]
    errors = []
    waits = []
    session = nil
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {},
      on_error: lambda { |error|
        errors << error
        session.stop if errors.length == 2
      },
      client_factory: ->(*) { clients.shift }, jitter: -> { 0.0 }
    )
    session.define_singleton_method(:wait) { |seconds| waits << seconds }

    session.run

    assert_equal [1.0, 1.0], waits
  end

  def test_stop_wakes_a_run_waiting_to_reconnect
    config = config_fixture
    entered_backoff = Queue.new
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(connected, *) { entered_backoff << true unless connected },
      on_error: ->(*) {},
      client_factory: ->(*) { FailingClient.new(IOError.new("offline")) }, jitter: -> { 0.0 }
    )
    runner = Thread.new { session.run }

    entered_backoff.pop
    session.stop

    Timeout.timeout(1) { runner.join }
    refute runner.alive?
  ensure
    session&.stop
    runner&.join(1)
  end

  def test_stop_unblocks_a_connected_run_waiting_for_reports
    config = config_fixture
    client = BlockingClient.new
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: ->(*) { client }, jitter: -> { 0.0 }
    )
    runner = Thread.new { session.run }

    client.wait_until_get
    session.stop

    refute_nil runner.join(0.2), "run remained blocked in client.get after stop"
  ensure
    session&.stop
    runner&.kill
    runner&.join
  end

  def test_stop_during_client_factory_prevents_late_connection
    config = config_fixture
    client = ConnectTrackingClient.new
    entered_factory = Queue.new
    release_factory = Queue.new
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: lambda { |*|
        entered_factory << true
        release_factory.pop
        client
      },
      jitter: -> { 0.0 }
    )
    runner = Thread.new { session.run }

    entered_factory.pop
    session.stop
    release_factory << true
    runner.join(1)

    assert_equal 0, client.connect_calls
    refute runner.alive?
  ensure
    release_factory << true if release_factory && release_factory.empty?
    session&.stop
    runner&.kill
    runner&.join
  end

  def test_stop_does_not_wait_for_a_blocked_connect
    config = config_fixture
    client = BlockingConnectClient.new
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: ->(*) { client }, jitter: -> { 0.0 }
    )
    runner = Thread.new { session.run }

    client.wait_until_connect
    stopper = Thread.new { session.stop }

    refute_nil stopper.join(0.2), "stop remained blocked behind client.connect"
    refute_nil runner.join(0.2), "run remained blocked in client.connect after stop"
  ensure
    client&.release_connect
    session&.stop
    stopper&.kill
    stopper&.join
    runner&.kill
    runner&.join
  end

  def test_report_callback_can_stop_its_own_session
    config = config_fixture
    client = BlockingClient.new
    session = nil
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret",
      on_report: ->(*) { session.stop }, on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: ->(*) { client }, jitter: -> { 0.0 }
    )
    runner = Thread.new { session.run }

    client.wait_until_get
    client.deliver(JSON.generate("print" => {}))

    refute_nil runner.join(0.2), "run remained blocked when on_report called stop"
  ensure
    session&.stop
    runner&.kill
    runner&.join
  end

  def test_disconnect_failure_does_not_mask_read_failure_and_cleanup_still_runs
    config = config_fixture
    client = DisconnectFailingClient.new("print" => {})
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: ->(*) { client }
    )

    error = begin
      session.connect_once
    rescue StandardError => caught
      caught
    end

    assert_instance_of IOError, error
    assert_equal "connection closed", error.message
    assert_nil session.instance_variable_get(:@client)
    assert_nil session.instance_variable_get(:@reader_thread)
  end

  def test_default_client_uses_scoped_mqtts_credentials_and_pinned_certificate
    config = BambuCompanion::Config.from_h(
      "host" => "printer.local", "mqttPort" => 18_883,
      "serial" => "SERIAL_1", "username" => "lan-user",
      "mqttTlsFingerprint" => "AB" * 32,
      "ftpsTlsFingerprint" => "CD" * 32
    )
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {}
    )

    client = session.send(:build_client, config, "memory-secret")

    assert_equal "printer.local", client.host
    assert_equal 18_883, client.port
    assert client.ssl
    refute client.verify_host
    assert_equal OpenSSL::SSL::VERIFY_PEER, client.ssl_context.verify_mode
    assert client.ssl_context.verify_callback
    assert_equal "lan-user", client.username
    assert_equal "memory-secret", client.password
    assert_equal 8, client.connect_timeout
    assert_equal 5, client.ack_timeout
    assert_equal 15, client.keep_alive
    assert client.clean_session
    assert_match(/\Abambu-companion-/, client.client_id)
  end

  def test_pin_mismatch_is_translated_before_mqtt_credentials_can_be_accepted
    config = config_fixture
    client = FailingClient.new(
      OpenSSL::SSL::SSLError.new("certificate verify failed untrusted-data")
    )
    context = OpenSSL::SSL::SSLContext.new
    BambuCompanion::TlsCertificate.configure_pinned_context(
      context, config.mqtt_tls_fingerprint
    )
    verifier = context.instance_variable_get(
      BambuCompanion::TlsCertificate::VERIFIER_IVAR
    )
    verifier.instance_variable_set(:@rejected, true)
    client.define_singleton_method(:ssl_context) { context }
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: ->(*) { client }
    )

    error = assert_raises(BambuCompanion::TlsCertificateError) do
      session.connect_once
    end

    assert_equal "certificate_changed", error.code
    refute_includes error.full_message, "untrusted-data"
  end

  def test_certificate_change_stops_the_retry_loop
    config = config_fixture
    error = BambuCompanion::TlsCertificateError.new(
      "certificate_changed", "Printer TLS certificate changed"
    )
    attempts = 0
    session = BambuCompanion::MqttSession.new(
      config: config, secret: "memory-secret", on_report: ->(*) {},
      on_connection: ->(*) {}, on_error: ->(*) {},
      client_factory: lambda do |*|
        attempts += 1
        FailingClient.new(error)
      end,
      jitter: -> { 0.0 }
    )

    runner = Thread.new { session.run }

    refute_nil runner.join(0.2), "certificate mismatch entered MQTT backoff"
    assert_equal 1, attempts
  ensure
    session&.stop
    runner&.kill
    runner&.join
  end
end
