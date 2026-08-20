#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d /tmp/bambu-companion-desktop-entry.XXXXXX)"
trap 'rm -r -- "$test_root"' EXIT

data_root="$test_root/data"
helper="$repo_root/bambu-companion-desktop-entry"
desktop_id="io.github.ypmrg.bambu-companion"
desktop_target="$data_root/applications/$desktop_id.desktop"
icon_target="$data_root/icons/hicolor/scalable/apps/$desktop_id.svg"

if XDG_DATA_HOME="$data_root" "$helper" status; then
  echo "desktop entry unexpectedly existed before installation" >&2
  exit 1
fi

XDG_DATA_HOME="$data_root" "$helper" install
XDG_DATA_HOME="$data_root" "$helper" status

[[ -f "$desktop_target" ]]
[[ -f "$icon_target" ]]
[[ "$(stat -c '%a' "$desktop_target")" == 644 ]]
[[ "$(stat -c '%a' "$icon_target")" == 644 ]]
grep -qx 'X-Bambu-Companion-Managed=true' "$desktop_target"
grep -qx 'Exec=omarchy-shell shell summon io.github.ypmrg.bambu-companion "{}"' \
  "$desktop_target"
desktop-file-validate "$desktop_target"

# Installation is idempotent for the entry managed by this plugin.
XDG_DATA_HOME="$data_root" "$helper" install

XDG_DATA_HOME="$data_root" "$helper" uninstall
[[ ! -e "$desktop_target" ]]
[[ ! -e "$icon_target" ]]

mkdir -p -- "$data_root/applications"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Unmanaged' \
  >"$desktop_target"
if XDG_DATA_HOME="$data_root" "$helper" install \
    >"$test_root/conflict.out" 2>"$test_root/conflict.err"; then
  echo "helper replaced an unmanaged desktop entry" >&2
  exit 1
fi
grep -qx 'Name=Unmanaged' "$desktop_target"
grep -qx 'bambu-companion-desktop-entry: refusing to replace an unmanaged desktop entry' \
  "$test_root/conflict.err"

# A matching marker behind a symbolic link is still never considered managed.
rm -f -- "$desktop_target"
protected_target="$test_root/protected.desktop"
printf '%s\n' '[Desktop Entry]' 'Type=Application' \
  'X-Bambu-Companion-Managed=true' >"$protected_target"
ln -s -- "$protected_target" "$desktop_target"
if XDG_DATA_HOME="$data_root" "$helper" install \
    >"$test_root/symlink.out" 2>"$test_root/symlink.err"; then
  echo "helper followed a symbolic-link desktop entry" >&2
  exit 1
fi
grep -qx 'X-Bambu-Companion-Managed=true' "$protected_target"
! grep -q '^Name=' "$protected_target"
[[ -L "$desktop_target" ]]

echo "Desktop entry install and removal are explicit, idempotent, and guarded."
