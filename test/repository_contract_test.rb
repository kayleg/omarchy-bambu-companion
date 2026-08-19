# frozen_string_literal: true

require_relative "test_helper"
require "json"

class RepositoryContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REQUIRED = %w[
    .gitignore manifest.json BambuWidget.qml bambu-companion daemon.rb Gemfile Gemfile.lock
    README.md LICENSE tests/test-all native/build
  ].freeze

  def test_required_installable_files_exist
    REQUIRED.each { |path| assert File.file?(File.join(ROOT, path)), "missing #{path}" }
    %w[bambu-companion tests/test-all tests/test-wrapper tests/fake-bundle tests/fake-gem native/build].each do |path|
      assert File.executable?(File.join(ROOT, path)), "#{path} must be executable"
    end
  end

  def test_frozen_lockfile_has_a_checksum_for_every_gem
    lockfile = File.read(File.join(ROOT, "Gemfile.lock"))
    checksums = lockfile[/^CHECKSUMS\n(?<entries>.*?)(?=\n^[A-Z][A-Z ]+\n)/m, :entries]
    refute_nil checksums

    entries = checksums.lines.map(&:strip).reject(&:empty?)
    refute_empty entries
    entries.each do |entry|
      assert_match(/\A.+ sha256=[0-9a-f]{64}\z/, entry,
                   "missing locked checksum for #{entry}")
    end
  end

  def test_manifest_identifies_the_bar_widget_and_uses_non_secret_defaults
    manifest = JSON.parse(File.read(File.join(ROOT, "manifest.json")))
    defaults = manifest.fetch("barWidget").fetch("defaults")

    assert_equal "io.github.ypmrg.bambu-companion", manifest.fetch("id")
    assert_equal "1.0.0", manifest.fetch("version")
    assert_includes manifest.fetch("kinds"), "bar-widget"
    assert_equal "BambuWidget.qml", manifest.fetch("entryPoints").fetch("barWidget")
    assert_equal "", defaults.fetch("host")
    assert_equal 8883, defaults.fetch("mqttPort")
    assert_equal 990, defaults.fetch("ftpsPort")
    assert_equal "", defaults.fetch("serial")
    assert_equal "3D Printer", defaults.fetch("printerName")
    assert_equal "bblp", defaults.fetch("username")
    refute defaults.key?("accessCode")
    refute defaults.key?("password")
  end

  def test_readme_documents_installation_security_dependencies_and_vm_validation
    readme = File.read(File.join(ROOT, "README.md"))

    ["omarchy plugin add", "GNOME Keyring", "omarchy plugin validate", "MQTT", "FTPS", "Node.js"].each do |text|
      assert_includes readme, text
    end
    assert_includes readme, "Omarchy Quattro"
    assert_includes readme, "tests/test-all"
    assert_includes readme, "development only"
    assert_includes readme, "COMPILING ROUTE RENDERER"
    assert_includes readme, "cmake"
    assert_includes readme, "g++"
    assert_includes readme, "GcodeRoute"
    refute_includes readme, "samples large routes within fixed budgets"
    refute_includes readme, "Canvas renderer"
    refute_includes readme, "Canvas rendering"
  end

  def test_readme_documents_explicit_first_use_certificate_approval
    readme = File.read(File.join(ROOT, "README.md"))

    assert_match(/Save & Connect.*check.*certificate.*TRUST & CONNECT/im, readme)
    assert_match(/SHA-256.*MQTT.*FTPS/im, readme)
    assert_match(/certificate changes.*block.*reconnect/im, readme)
    assert_match(/existing installations.*approve.*once/im, readme)
    refute_match(/certificate.*verification.*disabled/i, readme)
  end

  def test_offline_demo_feature_and_fixtures_are_absent
    production_paths = %w[manifest.json BambuWidget.qml BambuSettingsView.qml README.md]
      .concat(Dir[File.join(ROOT, "lib/**/*.rb")])
    production = production_paths.map do |path|
      File.read(path.start_with?(ROOT) ? path : File.join(ROOT, path))
    end.join("\n")

    refute_match(/demoMode|Offline demo mode|start_demo|demo_thread/i, production)
    refute File.exist?(File.join(ROOT, "fixtures/demo.gcode"))
    refute File.exist?(File.join(ROOT, "fixtures/demo-report.json"))
  end

  def test_vm_instructions_do_not_claim_that_plugin_add_installs_a_local_checkout
    readme = File.read(File.join(ROOT, "README.md"))

    refute_includes readme, 'omarchy plugin add "$PWD"'
    assert_includes readme, "omarchy-shell shell rescanPlugins"
    assert_includes readme, "omarchy plugin enable io.github.ypmrg.bambu-companion"
  end

  def test_production_configuration_has_no_default_lan_code
    production = %w[manifest.json BambuWidget.qml daemon.rb bambu-companion]
      .concat(Dir[File.join(ROOT, "lib/**/*.rb")].map { |path| path.delete_prefix("#{ROOT}/") })
      .map { |path| File.read(File.join(ROOT, path)) }.join("\n")

    refute_match(/access(?:_|)code\s*[=:]\s*["']12345678["']/i, production)
    refute_match(/password\s*[=:]\s*["']12345678["']/i, production)
    refute_match(/192\.168\.1\.54|0309DA541001354|grMpy|Fabricator/i, production)
  end

  def test_local_transports_explicitly_use_required_tls_modes
    mqtt = File.read(File.join(ROOT, "lib/bambu_companion/mqtt_session.rb"))
    ftps = File.read(File.join(ROOT, "lib/bambu_companion/ftps_client.rb"))
    tls = File.read(File.join(ROOT, "lib/bambu_companion/tls_certificate.rb"))

    assert_includes mqtt, "verify_host: false"
    assert_includes mqtt, "configure_pinned_context"
    assert_includes ftps, "implicit_ftps: true"
    assert_includes ftps, "private_data_connection: false"
    assert_includes ftps, 'sendcmd("PBSZ 0")'
    assert_includes ftps, 'sendcmd("PROT P")'
    assert_includes ftps, "instance_variable_set(:@private_data_connection, true)"
    assert_includes ftps, "configure_pinned_context"
    assert_includes tls, "OpenSSL::SSL::VERIFY_PEER"
    refute_includes mqtt, "OpenSSL::SSL::VERIFY_NONE"
    refute_includes ftps, "OpenSSL::SSL::VERIFY_NONE"
  end

  def test_development_checks_run_high_signal_linters
    rubocop_path = File.join(ROOT, ".rubocop.yml")
    assert File.file?(rubocop_path), "missing .rubocop.yml"

    rubocop_config = File.read(rubocop_path)
    test_all = File.read(File.join(ROOT, "tests/test-all"))

    assert_includes rubocop_config, "DisabledByDefault: true"
    assert_match(/^Lint:\n\s+Enabled: true$/m, rubocop_config)
    assert_match(/^Security:\n\s+Enabled: true$/m, rubocop_config)
    assert_includes test_all, "rubocop --cache false"
    assert_includes test_all, "shellcheck"
    assert_match(/qmllint.*\*\.qml/, test_all)
  end

  def test_user_configuration_changes_require_an_explicit_widget_action
    widget = File.read(File.join(ROOT, "BambuWidget.qml"))
    launcher = File.read(File.join(ROOT, "bambu-companion"))
    readme = File.read(File.join(ROOT, "README.md"))

    assert_equal 1, widget.scan("root.bar.shell.updateEntryInline(root.moduleName, entry)").length
    assert_match(/function commitSettingsEntry\(entry\).*updateEntryInline\(root\.moduleName, entry\)/m,
                 widget)
    assert_match(/function saveSettings\(.*persistSettings\(draft\)/m, widget)
    assert_match(/onBarSummaryToggled:.*persistBarSummary\(enabled\)/m, widget)
    refute_match(%r{(?:\$HOME|~)/\.config}, launcher)
    assert_includes readme, "does not overwrite user configuration"
  end
end
