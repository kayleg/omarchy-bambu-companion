# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class QmlEventStoreTest < Minitest::Test
  def test_event_store_behavior_in_qml_runtime
    runner = qml_test_runner
    skip "qmltestrunner is unavailable" unless runner

    root = File.expand_path("..", __dir__)
    environment = {
      "DISPLAY" => nil,
      "QT_QPA_PLATFORMTHEME" => nil,
      "QT_QPA_PLATFORM" => "offscreen",
      "QT_QUICK_BACKEND" => "software"
    }
    output, errors, status = Open3.capture3(
      environment, runner,
      "-input", File.join(__dir__, "qml"), "-import", root
    )

    assert status.success?, [output, errors].reject(&:empty?).join("\n")
    assert_includes output, "5 passed"
    assert_includes output, "0 failed"
  end

  private

  def qml_test_runner
    candidates = ENV["QMLTESTRUNNER"].to_s.empty? ? [] : [ENV["QMLTESTRUNNER"]]
    candidates.concat(ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
      File.join(directory, "qmltestrunner")
    end)
    candidates.concat(%w[/usr/lib/qt6/bin/qmltestrunner /usr/lib/qt6/libexec/qmltestrunner])
    candidates.find { |path| File.file?(path) && File.executable?(path) }
  end
end
