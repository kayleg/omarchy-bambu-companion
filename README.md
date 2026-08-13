# Bambu Companion for Omarchy Quattro

Monitor a Bambu Lab printer from the Omarchy Quattro bar. Bambu Companion
shows live print telemetry and renders a lightweight, interactive 3D wireframe
from the G-code available on the printer.

## Install

```bash
omarchy plugin add https://github.com/ypMrg/omarchy-bambu-companion.git --enable
```

On first launch, the plugin installs its locked Ruby dependencies in an
isolated user-data directory. System gems are never modified. Internet access
is only required for this initial dependency installation.

Update or remove the plugin with:

```bash
omarchy plugin update io.github.ypmrg.bambu-companion --yes
omarchy restart shell

omarchy plugin remove io.github.ypmrg.bambu-companion
```

If the widget is enabled but not present in the bar, place it explicitly:

```bash
omarchy plugin enable io.github.ypmrg.bambu-companion --section right
omarchy restart shell
```

## Setup

On first load, Bambu Companion automatically opens its setup panel. A
connection loader remains until the first fresh status report is received;
only then does the live dashboard appear.

1. Enable local network access on the printer and obtain its serial number and
   LAN access code from the printer's network settings.
2. Open the Bambu Companion widget.
3. Enter the printer address, serial number and LAN access code.
4. Select **Save & Connect**.

The exact printer menu names vary by model and firmware. This plugin uses the
local Bambu MQTT and FTPS services; it does not connect to Bambu Cloud.

### Configuration

| Setting | Default | Description |
| --- | --- | --- |
| Printer name | `3D Printer` | Name displayed in the dashboard |
| Printer address | — | IPv4, IPv6 address or hostname |
| Serial number | — | Printer serial used by MQTT topics |
| MQTT TLS port | `8883` | Local encrypted telemetry service |
| FTPS port | `990` | Local implicit-FTPS file service |
| MQTT / FTPS username | `bblp` | Local Bambu service account |
| LAN access code | — | Password shown by the printer |
| Wireframe segment limit | `40000` | Detail/performance limit, from 1,000 to 100,000 |
| Accent color | `#39FF88` | Wireframe and active-state color |
| Bar summary | enabled | Show or hide status, progress and temperatures in the bar |

The **Bar summary** toggle is applied immediately. Other configuration changes
are applied with **Save & Connect**.

Settings and the live dashboard reflow at narrow widths so every control stays
inside the panel margins.

When a code is already available, Settings reports whether it is stored in
GNOME Keyring or active only for the current session. Leave the code field
blank to keep it, enter another code to replace it, or use **Forget code** to
remove it.

## Features

- Compact bar icon with optional status, progress and temperature summary.
- Live connection, print state, progress and remaining-time reporting.
- Current and target nozzle/bed temperatures.
- Current layer, total layers and exact or estimated Z progress.
- Speed profile, fan speeds, Wi-Fi signal and last report time.
- Landscape dashboard with telemetry on the left and 3D preview on the right.
- Configurable accent color and wireframe detail limit.
- Automatic reconnect after temporary network loss.
- Monitoring-only operation: no pause, resume, stop, upload or speed commands.

After a completed print, `FINISH` remains visible for 60 seconds and then
settles to `READY`. Starting another job cancels that delay immediately.

## 3D print preview

When a job starts, the backend identifies its print file, downloads it over
FTPS and keeps only recognized outer-wall moves. A new print automatically
starts a new model generation; late data from the previous job is discarded.
This also works when the same file is printed again after the previous job has
finished.

During printer calibration, heating or file preparation, the model may not be
available yet. The plugin explains this state and retries automatically. Use
**Reload model** to request another attempt manually.

Preview controls:

| Input | Action |
| --- | --- |
| Drag horizontally | Rotate around the model |
| Drag vertically | Inspect from above or below |
| Hold the pointer | Pause automatic rotation |
| Mouse wheel | Zoom from `0.50×` to `4.00×` |
| Auto-rotate | Enable or disable continuous rotation |

Printed paths use the configured accent color; remaining paths stay subdued.
The renderer samples very large models uniformly so the silhouette and both
ends of the toolpath remain representative without overloading the bar.

### Supported print files

- Direct `.gcode` files.
- Bambu Studio or OrcaSlicer `.gcode.3mf` files.
- Unambiguous `.3mf` archives containing `Metadata/plate_*.gcode`.
- Outer-wall markers produced by Bambu Studio, OrcaSlicer,
  PrusaSlicer/SuperSlicer and Cura.

Ambiguous multi-plate archives, corrupt files, oversized input or G-code
without recognized outer-wall markers produce a model-only error. MQTT status
monitoring continues normally.

## Printer compatibility

Bambu Companion has been live-tested with a Bambu Lab A1 Mini. It is expected
to work with A1-series and other Bambu printers exposing the same local MQTT,
implicit-FTPS and G-code conventions, but compatibility with every model and
firmware version is not guaranteed.

The printer must expose its local services and provide a LAN access code. Cloud
telemetry used by Bambu Handy is outside this plugin's scope.

## Security and local storage

- The plugin does not overwrite user configuration without explicit consent:
  printer settings are written only with **Save & Connect**, and the bar-summary
  preference only when its toggle is changed.
- The LAN access code is never stored in plugin settings, the repository,
  process arguments or normal logs.
- `secret-tool` stores the code in GNOME Keyring when available. Otherwise it
  remains only in the current backend process memory.
- The code is passed to the Ruby backend and GNOME Keyring through standard
  input, not command-line arguments.
- Downloaded G-code/3MF files use private temporary files and are deleted after
  parsing, cancellation or failure. No persistent print-file cache is kept.
- Only the simplified geometry remains in memory and is replaced by the next
  model generation.

Bambu printers use local self-signed certificates. Certificate and hostname
verification are therefore disabled only for the configured printer's MQTT
and FTPS TLS sessions. Use the plugin on a trusted LAN.

## Requirements

- Omarchy Quattro v4.
- Printer and Omarchy machine reachable on the same trusted network.
- Local printer access and a valid LAN access code.
- `ruby`, `gem`, `flock` and GNU `readlink`.
- `secret-tool`/GNOME Keyring recommended for persistent secret storage.

The launcher installs the exact Bundler version from `Gemfile.lock` when
`bundle` is unavailable, then installs all locked gems under the plugin's
private data directory.

## Troubleshooting

### The widget is missing

```bash
omarchy plugin list --json
omarchy plugin enable io.github.ypmrg.bambu-companion --section right
omarchy restart shell
```

### The printer remains offline

- Verify the address, serial number, ports, username and LAN access code.
- Confirm that local printer access is enabled and both devices share a LAN.
- Replace the saved code if the printer generated a new one.
- Check that a firewall is not blocking TCP ports `8883` and `990`.

### The model is unavailable

- Wait while the printer finishes calibration, heating and file preparation.
- Confirm that a supported G-code or 3MF file is present on the printer.
- Select **Reload model** after the print has entered `RUNNING`.
- Status monitoring remains usable even when model extraction fails.

### Inspect Quickshell logs

```bash
journalctl -t omarchy-shell -b --no-pager \
  | grep -Ei 'bambu|plugin widget|failed|error'
```

## Development and validation

Run all local checks from the repository root:

```bash
tests/test-all
```

This verifies the production bundle, Ruby and shell syntax, high-signal
RuboCop and ShellCheck rules, JSON/QML contracts, launcher isolation, parser
behavior and Canvas rendering. `minitest`, `rubocop`, `shellcheck`, `qmllint`
and Node.js are development only; none is a runtime dependency of the installed
plugin.

Validate a checkout inside Omarchy Quattro with:

```bash
omarchy plugin validate "$PWD"
tests/test-all
```

For an unpublished checkout in a disposable Quattro VM:

```bash
plugin_target="$HOME/.config/omarchy/plugins/io.github.ypmrg.bambu-companion"
test ! -e "$plugin_target"
mkdir -p "$plugin_target"
cp -a -- "$PWD/." "$plugin_target/"
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.ypmrg.bambu-companion --section right
omarchy restart shell
```

## Architecture

- `BambuWidget.qml` and the smaller QML components implement the bar,
  dashboard, settings and Canvas renderer.
- `daemon.rb` launches the Ruby backend.
- MQTT provides printer telemetry; implicit FTPS provides the active print
  file.
- The Ruby parser streams and downsamples outer-wall G-code into bounded
  geometry.
- Newline-delimited JSON over stdin/stdout connects the isolated backend to
  Quickshell.

The current release supports one printer. Multi-printer dashboards, camera
streams, cloud access and printer-control actions are intentionally excluded.

## License

[MIT](LICENSE) — Copyright (c) 2026 Matthieu G.C.

Bambu Lab names and trademarks belong to their respective owners. This project
is independent and is not affiliated with or endorsed by Bambu Lab.
