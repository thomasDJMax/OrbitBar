#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/OrbitBar-rendering.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$PROJECT_DIR"
swiftc -swift-version 6 -emit-library -emit-module -module-name OrbitBarCore \
  Sources/OrbitBarCore/*.swift \
  -emit-module-path "$TEST_DIR/OrbitBarCore.swiftmodule" -o "$TEST_DIR/libOrbitBarCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" -L "$TEST_DIR" -lOrbitBarCore \
  -Xlinker -rpath -Xlinker "$TEST_DIR" \
  Sources/OrbitBar/AppSettings.swift Sources/OrbitBar/IconRenderer.swift \
  Sources/OrbitBar/MenuBarIconView.swift Sources/OrbitBar/StatusAccessory.swift \
  Sources/OrbitBar/VolumeAnimator.swift scripts/test-rendering.swift \
  -o "$TEST_DIR/rendering-regressions"
"$TEST_DIR/rendering-regressions"
