#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d /tmp/bambu-companion-update-check.XXXXXX)"
trap 'rm -r -- "$test_root"' EXIT

remote="$test_root/remote.git"
upstream="$test_root/upstream"
checkout="$test_root/checkout"

git init --quiet --bare "$remote"
git init --quiet --initial-branch=master "$upstream"
git -C "$upstream" config user.email test@example.com
git -C "$upstream" config user.name "Bambu Companion Test"
cp -- "$repo_root/bambu-companion-update-check" "$upstream/"
printf '%s\n' '{' '  "version": "1.2.5"' '}' >"$upstream/manifest.json"
git -C "$upstream" add bambu-companion-update-check manifest.json
git -C "$upstream" commit --quiet -m initial
git -C "$upstream" remote add origin "$remote"
git -C "$upstream" push --quiet --set-upstream origin master
git clone --quiet "$remote" "$checkout"

if "$checkout/bambu-companion-update-check"; then
  echo "update check reported the installed version as outdated" >&2
  exit 1
fi

sed -i 's/1\.2\.5/1.3.1/' "$upstream/manifest.json"
git -C "$upstream" add manifest.json
git -C "$upstream" commit --quiet -m update
git -C "$upstream" push --quiet

[[ "$("$checkout/bambu-companion-update-check")" == "1.3.1" ]]

sed -i 's/1\.2\.5/1.4.0/' "$checkout/manifest.json"
if "$checkout/bambu-companion-update-check"; then
  echo "update check offered a remote version older than the installed version" >&2
  exit 1
fi

echo "Plugin update checks compare validated manifest versions."
