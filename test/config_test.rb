# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "bambu_companion/config"

class ConfigTest < Minitest::Test
  def test_known_defaults_exclude_printer_identity
    config = test_printer_config

    assert_equal "192.168.1.50", config.host
    assert_equal 8883, config.mqtt_port
    assert_equal 990, config.ftps_port
    assert_equal "0309C123456789", config.serial
    assert_equal "bblp", config.username
    assert_equal 500_000, config.max_segments
    assert_equal "11" * 32, config.mqtt_tls_fingerprint
    assert_equal "22" * 32, config.ftps_tls_fingerprint
    refute_respond_to config, :to_h
    refute_respond_to config, :demo_mode
  end

  def test_host_and_serial_are_always_required
    assert_raises(BambuCompanion::ConfigError) { BambuCompanion::Config.from_h({}) }
    assert_raises(BambuCompanion::ConfigError) do
      BambuCompanion::Config.from_h("host" => "printer.local")
    end
    assert_raises(BambuCompanion::ConfigError) do
      BambuCompanion::Config.from_h("serial" => "SERIAL_1")
    end

    assert_raises(BambuCompanion::ConfigError) do
      BambuCompanion::Config.from_h("demoMode" => true)
    end
  end

  def test_accepts_qml_camel_case_keys
    config = BambuCompanion::Config.from_h(
      "host" => "printer.local", "mqttPort" => "18883",
      "ftpsPort" => 1990, "serial" => "SERIAL_1",
      "username" => "lan-user", "maxSegments" => 12_000,
      "demoMode" => true
    )

    assert_equal 18_883, config.mqtt_port
    assert_equal 1_990, config.ftps_port
    assert_equal 12_000, config.max_segments
    refute_respond_to config, :demo_mode
  end

  def test_accepts_free_form_network_addresses
    ["printer.local", "fe80::54%enp1s0", "[fd00::54]"].each do |host|
      assert_equal host, test_printer_config("host" => host).host
    end
  end

  def test_normalizes_optional_tls_fingerprints
    config = test_printer_config(
      "mqttTlsFingerprint" => Array.new(32, "ab").join(":"),
      "ftpsTlsFingerprint" => "cd" * 32
    )

    assert_equal "AB" * 32, config.mqtt_tls_fingerprint
    assert_equal "CD" * 32, config.ftps_tls_fingerprint
    refute BambuCompanion::Config.from_h(
      printer_config(
        "mqttTlsFingerprint" => "", "ftpsTlsFingerprint" => nil
      )
    ).trusted_tls?
    assert config.trusted_tls?
  end

  def test_rejects_malformed_tls_fingerprints
    %w[AA invalid].each do |fingerprint|
      assert_raises(BambuCompanion::ConfigError) do
        test_printer_config("mqttTlsFingerprint" => fingerprint)
      end
      assert_raises(BambuCompanion::ConfigError) do
        test_printer_config("ftpsTlsFingerprint" => fingerprint)
      end
    end
  end

  def test_bounds_and_sanitizes_network_address
    ["", "bad\0host", "a" * 256].each do |host|
      assert_raises(BambuCompanion::ConfigError) do
        test_printer_config("host" => host)
      end
    end
  end

  def test_bounds_printer_identity_tokens
    %w[serial username].each do |key|
      assert_raises(BambuCompanion::ConfigError) do
        test_printer_config(key => "a" * 129)
      end
    end
  end

  def test_rejects_invalid_values_without_partial_config
    assert_raises(BambuCompanion::ConfigError) do
      test_printer_config("mqttPort" => 0)
    end
    assert_raises(BambuCompanion::ConfigError) do
      test_printer_config("serial" => "bad serial\n")
    end
  end

  def test_manifest_contains_no_access_code_setting
    root = File.expand_path("..", __dir__)
    manifest = JSON.parse(File.read(File.join(root, "manifest.json")))
    keys = manifest.fetch("barWidget").fetch("schema").map { |entry| entry.fetch("key") }

    assert_equal 1, manifest.fetch("schemaVersion")
    assert_equal "io.github.ypmrg.bambu-companion", manifest.fetch("id")
    assert_equal ["bar-widget"], manifest.fetch("kinds")
    assert_equal "BambuWidget.qml", manifest.dig("entryPoints", "barWidget")
    refute_includes keys, "accessCode"
    refute_includes secret_values(manifest), "12345678"
  end

  def test_secret_values_detects_secret_schema_keys
    manifest = {
      "barWidget" => {
        "schema" => [{ "key" => "password", "defaultValue" => "12345678" }]
      }
    }

    assert_includes secret_values(manifest), "12345678"
  end

  private

  def secret_values(value)
    case value
    when Hash
      return [value["defaultValue"]] if secret_key?(value["key"])

      value.flat_map do |key, child|
        secret_key?(key) ? [child] : secret_values(child)
      end
    when Array
      value.flat_map { |child| secret_values(child) }
    else
      []
    end
  end

  def secret_key?(key)
    key&.match?(/\A(access_?code|password|passcode|secret)\z/i)
  end
end
