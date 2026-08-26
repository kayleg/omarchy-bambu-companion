# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "bambu_companion/config"

module BambuCompanion
  module TestFixtures
    PRINTER_CONFIG = {
      "host" => "192.168.1.50",
      "serial" => "0309C123456789",
      "mqttTlsFingerprint" => "11" * 32,
      "ftpsTlsFingerprint" => "22" * 32
    }.freeze

    def self.minimal_jpeg(width: 1, height: 1, payload: "")
      sof = [11, 8, height, width, 1, 1, 0x11, 0].pack("nCnnCCCC")
      "\xFF\xD8\xFF\xC0".b + sof + payload.to_s.b + "\xFF\xD9".b
    end
  end
end

class Minitest::Test
  def printer_config(overrides = {})
    BambuCompanion::TestFixtures::PRINTER_CONFIG.merge(overrides.transform_keys(&:to_s))
  end

  def minimal_jpeg(**arguments)
    BambuCompanion::TestFixtures.minimal_jpeg(**arguments)
  end

  def config_fixture(overrides = {})
    BambuCompanion::Config.from_h(printer_config(overrides))
  end
end
