#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/OrbitBar-settings.XXXXXX")"
export ORBITBAR_SETTINGS_TEST_DOMAIN="com.thomas.OrbitBar.settings-regression.$(uuidgen)"
cleanup() {
  # The shell also cleans the dedicated domains after an assertion or crash,
  # when the Swift process cannot reach its defer block.
  /usr/bin/defaults delete "$ORBITBAR_SETTINGS_TEST_DOMAIN.corrupt" >/dev/null 2>&1 || true
  /usr/bin/defaults delete "$ORBITBAR_SETTINGS_TEST_DOMAIN.saved" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
cd "$PROJECT_DIR"
swiftc -swift-version 6 -emit-library -emit-module -module-name OrbitBarCore \
  Sources/OrbitBarCore/AppearancePreferences.swift \
  -emit-module-path "$TEST_DIR/OrbitBarCore.swiftmodule" -o "$TEST_DIR/libOrbitBarCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" -L "$TEST_DIR" -lOrbitBarCore \
  -Xlinker -rpath -Xlinker "$TEST_DIR" \
  Sources/OrbitBar/AppSettings.swift scripts/test-settings.swift -o "$TEST_DIR/settings-regressions"
"$TEST_DIR/settings-regressions"
