#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d /tmp/bambu-companion-wrapper.XXXXXX)"
trap 'rm -r -- "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/data"
cp "$repo_root/test/support/fake-bundle" "$test_root/bin/bundle"
chmod +x "$test_root/bin/bundle"
ln -s "$repo_root/bambu-companion" "$test_root/bin/bambu-companion"
log="$test_root/bundle.log"
environment_log="$test_root/bundle-environment.log"

output="$({
  PATH="$test_root/bin:$PATH" \
  XDG_DATA_HOME="$test_root/data" \
  FAKE_BUNDLE_LOG="$log" \
  FAKE_BUNDLE_ENV_LOG="$environment_log" \
  FAKE_BUNDLE_ASSERT_FD9_CLOSED=1 \
  FAKE_BUNDLE_CHECK_EXIT=1 \
  BUNDLE_GEMFILE="$test_root/malicious.Gemfile" \
  BUNDLE_CACHE_PATH="$test_root/malicious-cache" \
  BUNDLE_PATH__SYSTEM=true \
  BAMBU_COMPANION_DAEMON="$test_root/malicious-daemon.rb" \
  "$test_root/bin/bambu-companion"
})"

grep -qx "$repo_root/Gemfile" <<<"$output"
grep -qx "$test_root/data/io.github.ypmrg.bambu-companion/bundle" <<<"$output"
grep -q '^check$' "$log"
grep -q '^install --jobs 2 --retry 2$' "$log"
grep -qx "exec ruby $repo_root/daemon.rb" "$log"
grep -qx "BUNDLE_GEMFILE=$repo_root/Gemfile" "$environment_log"
grep -qx "BUNDLE_PATH=$test_root/data/io.github.ypmrg.bambu-companion/bundle" "$environment_log"
grep -qx "BUNDLE_CACHE_PATH=$test_root/data/io.github.ypmrg.bambu-companion/bundle/cache" "$environment_log"
grep -qx "BUNDLE_USER_HOME=$test_root/data/io.github.ypmrg.bambu-companion/bundler-user" "$environment_log"
grep -qx "BUNDLE_USER_CACHE=$test_root/data/io.github.ypmrg.bambu-companion/bundler-user/cache" "$environment_log"
grep -qx 'BUNDLE_IGNORE_CONFIG=true' "$environment_log"
grep -qx 'BUNDLE_WITHOUT=development' "$environment_log"
grep -qx 'BUNDLE_PATH__SYSTEM=' "$environment_log"
for directory in \
  "$test_root/data/io.github.ypmrg.bambu-companion" \
  "$test_root/data/io.github.ypmrg.bambu-companion/bundle" \
  "$test_root/data/io.github.ypmrg.bambu-companion/bundle/cache" \
  "$test_root/data/io.github.ypmrg.bambu-companion/bundler-user" \
  "$test_root/data/io.github.ypmrg.bambu-companion/bundler-user/cache"; do
  [[ "$(stat -c '%a' "$directory")" == 700 ]]
done
if grep -q '12345678\|accessCode\|session-secret' "$log"; then
  echo "wrapper leaked a secret-like value" >&2
  exit 1
fi

if env -u XDG_DATA_HOME -u HOME \
  PATH="$test_root/bin:$PATH" \
  FAKE_BUNDLE_LOG="$log" \
  "$repo_root/bambu-companion" >"$test_root/no-home.out" 2>"$test_root/no-home.err"; then
  echo "wrapper started without XDG_DATA_HOME or HOME" >&2
  exit 1
fi
grep -qx 'bambu-companion: XDG_DATA_HOME or HOME must be set' "$test_root/no-home.err"

if PATH="$test_root/bin:$PATH" \
  XDG_DATA_HOME="$test_root/data-install-failure" \
  FAKE_BUNDLE_LOG="$test_root/install-failure.log" \
  FAKE_BUNDLE_CHECK_EXIT=1 \
  FAKE_BUNDLE_INSTALL_EXIT=1 \
  "$repo_root/bambu-companion" >"$test_root/install-failure.out" 2>"$test_root/install-failure.err"; then
  echo "wrapper accepted a failed dependency installation" >&2
  exit 1
fi
grep -qx 'bambu-companion: dependency installation failed.' "$test_root/install-failure.err"

bootstrap_root="$test_root/bootstrap"
bootstrap_bin="$bootstrap_root/bin"
bootstrap_data="$bootstrap_root/data"
mkdir -p "$bootstrap_bin" "$bootstrap_data"
for command_name in chmod dirname flock mkdir readlink ruby; do
  ln -s "$(command -v "$command_name")" "$bootstrap_bin/$command_name"
done
cp "$repo_root/test/support/fake-gem" "$bootstrap_bin/gem"
chmod +x "$bootstrap_bin/gem"
bootstrap_gem_log="$bootstrap_root/gem.log"
bootstrap_bundle_log="$bootstrap_root/bundle.log"
bootstrap_environment_log="$bootstrap_root/bundle-environment.log"

bootstrap_output="$({
  PATH="$bootstrap_bin" \
  XDG_DATA_HOME="$bootstrap_data" \
  FAKE_GEM_LOG="$bootstrap_gem_log" \
  FAKE_BUNDLE_SOURCE="$repo_root/test/support/fake-bundle" \
  FAKE_BUNDLE_LOG="$bootstrap_bundle_log" \
  FAKE_BUNDLE_ENV_LOG="$bootstrap_environment_log" \
  FAKE_BUNDLE_CHECK_EXIT=1 \
  "$repo_root/bambu-companion"
})"

bundler_home="$bootstrap_data/io.github.ypmrg.bambu-companion/bundler-runtime/4.0.4"
bundler_bin="$bootstrap_data/io.github.ypmrg.bambu-companion/bundler-bin/4.0.4"
grep -qx "install --config-file /dev/null --clear-sources --source https://rubygems.org --install-dir $bundler_home --bindir $bundler_bin --no-document bundler -v 4.0.4" \
  "$bootstrap_gem_log"
grep -qx 'check' "$bootstrap_bundle_log"
grep -qx 'install --jobs 2 --retry 2' "$bootstrap_bundle_log"
grep -qx "exec ruby $repo_root/daemon.rb" "$bootstrap_bundle_log"
grep -qx "$repo_root/Gemfile" <<<"$bootstrap_output"
grep -qx "$bootstrap_data/io.github.ypmrg.bambu-companion/bundle" <<<"$bootstrap_output"
grep -qx "GEM_HOME=$bundler_home" "$bootstrap_environment_log"
grep -qx "GEM_PATH=$bundler_home" "$bootstrap_environment_log"
[[ "$(stat -c '%a' "$bundler_home")" == 700 ]]
[[ "$(stat -c '%a' "$bundler_bin")" == 700 ]]

PATH="$bootstrap_bin" \
XDG_DATA_HOME="$bootstrap_data" \
FAKE_GEM_LOG="$bootstrap_gem_log" \
FAKE_BUNDLE_SOURCE="$repo_root/test/support/fake-bundle" \
FAKE_BUNDLE_LOG="$bootstrap_root/second-bundle.log" \
"$repo_root/bambu-companion" >/dev/null
[[ "$(wc -l <"$bootstrap_gem_log")" == 1 ]]

bootstrap_failure_root="$test_root/bootstrap-failure"
mkdir -p "$bootstrap_failure_root/bin"
for command_name in chmod dirname flock mkdir readlink ruby; do
  ln -s "$(command -v "$command_name")" "$bootstrap_failure_root/bin/$command_name"
done
cp "$repo_root/test/support/fake-gem" "$bootstrap_failure_root/bin/gem"
chmod +x "$bootstrap_failure_root/bin/gem"
if PATH="$bootstrap_failure_root/bin" \
  XDG_DATA_HOME="$bootstrap_failure_root/data" \
  FAKE_GEM_LOG="$bootstrap_failure_root/gem.log" \
  FAKE_BUNDLE_SOURCE="$repo_root/test/support/fake-bundle" \
  FAKE_GEM_INSTALL_EXIT=1 \
  "$repo_root/bambu-companion" \
  >"$bootstrap_failure_root/out" 2>"$bootstrap_failure_root/err"; then
  echo "wrapper accepted a failed Bundler bootstrap" >&2
  exit 1
fi
grep -qx 'bambu-companion: Bundler installation failed.' "$bootstrap_failure_root/err"

echo "Bundler is isolated and daemon argv contains no LAN secret."
