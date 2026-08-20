# frozen_string_literal: true

require_relative "test_helper"
require "json"

class DesktopAppContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @manifest = JSON.parse(File.read(File.join(ROOT, "manifest.json")))
    @app = File.read(File.join(ROOT, "BambuApp.qml"))
    @widget = File.read(File.join(ROOT, "BambuWidget.qml"))
    @dashboard = File.read(File.join(ROOT, "BambuDashboard.qml"))
    @settings = File.read(File.join(ROOT, "BambuSettingsView.qml"))
    @service = File.read(File.join(ROOT, "BambuService.qml"))
    @desktop_entry = File.read(
      File.join(ROOT, "io.github.ypmrg.bambu-companion.desktop")
    )
  end

  def test_manifest_exposes_one_shared_service_to_the_widget_and_app
    assert_equal %w[service bar-widget panel], @manifest.fetch("kinds")
    assert_equal "BambuService.qml", @manifest.dig("entryPoints", "service")
    assert_equal "BambuWidget.qml", @manifest.dig("entryPoints", "barWidget")
    assert_equal "BambuApp.qml", @manifest.dig("entryPoints", "panel")
    assert_equal 1, @service.scan(/BambuBackendSession\s*\{/).length
    assert_match(/serviceFor\(root\.moduleName\)/, @widget)
    assert_match(/BambuDashboard\s*\{.*service: root\.service/m, @widget)
    assert_match(/BambuDashboard\s*\{.*service: root\.service/m, @app)
  end

  def test_app_is_a_normal_resizable_compositor_managed_window
    assert_includes @app, "FloatingWindow {"
    refute_includes @app, "PanelWindow {"
    refute_match(/WlrLayershell|exclusiveZone|anchor\.edges|HyprlandWindowRule/i,
                 @app)
    assert_match(/title: "Bambu Companion"/, @app)
    assert_match(/implicitWidth: 1000.*implicitHeight: 640/m, @app)
    assert_match(/minimumSize: Qt\.size\(420, 320\)/, @app)
    assert_includes @dashboard, "required property real viewportHeight"
    assert_match(/height: wideLayout \? root\.viewportHeight/, @dashboard)
    refute_match(/height: wideLayout \? panelScroll\.height/, @dashboard)
    refute_match(/height: dashboard\.wideLayout \? dashboard\.height/, @dashboard)
    assert_match(/BambuDashboard\s*\{.*viewportHeight: appWindow\.height/m, @app)
    assert_match(/BambuDashboard\s*\{.*viewportHeight: Math\.max\(0, popupPanel\.contentHeight\s*- popupPanel\.verticalContentInset\)/m,
                 @widget)
    assert_match(/function open\(_\).*appWindow\.visible = true.*appWindow\.minimized = false/m,
                 @app)
    refute_match(/function open\(_\).*dashboard\.open\(\)/m, @app)
    assert_match(/onSurfaceActiveChanged:.*!root\.componentReady.*root\.surfaceActive.*root\.open\(\).*root\.close\(\)/m,
                 @dashboard)
    assert_match(/function requestClose\(\).*root\.shell\.hide\(root\.moduleName\)/m,
                 @app)
  end

  def test_widget_can_summon_the_app_without_starting_another_backend
    assert_match(/function openApp\(\).*root\.close\(\).*root\.bar\.shell\.summon\(root\.moduleName, "\{}"\)/m,
                 @widget)
    assert_match(/showOpenAppButton: true.*onOpenAppRequested: root\.openApp\(\)/m,
                 @widget)
    assert_match(/appButtonVisible: root\.showOpenAppButton.*onAppRequested: root\.openAppRequested\(\)/m,
                 @dashboard)
    refute_includes @widget, "BambuBackendSession {"
    refute_includes @app, "BambuBackendSession {"
    refute_match(/onAttentionRequested/, @dashboard)
    assert_match(/onAttentionRequested\(mode, message\).*root\.openAttention\(mode, message\)/m,
                 @widget)
    assert_match(/Connections\s*{.*target: root\.service.*onAttentionRequested\(mode, message\).*appWindow\.visible.*dashboard\.showAttention\(mode, message\)/m,
                 @app)
  end

  def test_launcher_entry_is_explicit_standard_and_reversible
    assert_includes @settings, "signal desktopEntryToggled(bool enabled)"
    assert_includes @settings, 'text: "DESKTOP"'
    assert_includes @settings, '"ADD TO APP LAUNCHER"'
    assert_includes @settings, '"REMOVE FROM APP LAUNCHER"'
    assert_match(/onDesktopEntryToggled: function\(enabled\).*root\.service\.setDesktopEntryEnabled\(enabled\).*!root\.service\.desktopEntryError/m,
                 @dashboard)
    assert_match(/function runDesktopEntryAction\(action\).*desktopEntryProcess\.command = \[root\.desktopEntryManagerPath, action\].*desktopEntryProcess\.running = true/m,
                 @service)
    assert_match(/function setDesktopEntryEnabled\(enabled\).*runDesktopEntryAction\(enabled === true \? "install" : "uninstall"\)/m,
                 @service)
    refute_match(/onDesktopEntryErrorChanged/, @dashboard)

    assert_includes @desktop_entry, "Type=Application"
    assert_includes @desktop_entry,
                    'Exec=omarchy-shell shell summon io.github.ypmrg.bambu-companion "{}"'
    assert_includes @desktop_entry, "TryExec=omarchy-shell"
    assert_includes @desktop_entry, "Terminal=false"
    assert_includes @desktop_entry, "Icon=io.github.ypmrg.bambu-companion"
    assert_includes @desktop_entry, "X-Bambu-Companion-Managed=true"
  end

  def test_sidebar_exposes_the_current_version_and_native_plugin_update
    telemetry = File.read(File.join(ROOT, "BambuTelemetryPane.qml"))

    assert_match(/SectionTitle \{ objectName: "APPLICATION" \}/, telemetry)
    assert_match(/text: "v" \+ pane\.appVersion/, telemetry)
    assert_match(/visible: pane\.updateAvailable.*text: "\\uf019"/m, telemetry)
    assert_match(/id: versionIndicator.*anchors\.verticalCenter: parent\.verticalCenter/m,
                 telemetry)
    assert_match(/id: versionText.*anchors\.verticalCenter: parent\.verticalCenter/m,
                 telemetry)
    assert_match(/id: updateButton.*anchors\.verticalCenter: parent\.verticalCenter/m,
                 telemetry)
    assert_match(/onClicked: pane\.updateRequested\(\)/, telemetry)
    assert_match(/appVersion: root\.service\.currentVersion.*updateAvailable: root\.service\.pluginUpdateAvailable.*onUpdateRequested: root\.service\.installPluginUpdate\(\)/m,
                 @dashboard)
    assert_match(/readonly property string currentVersion: root\.manifest.*root\.manifest\.version/m,
                 @service)
    assert_match(/\["omarchy", "plugin", "update", root\.moduleName, "--yes"\]/,
                 @service)
  end
end
