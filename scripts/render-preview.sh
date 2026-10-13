#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
swift build --product OrbitBar
BIN_DIR="$(swift build --show-bin-path)"
if [[ -f "$BIN_DIR/OrbitBarCore.o" ]]; then
    MODULE_DIR="$BIN_DIR"
    CORE_OBJECTS=("$BIN_DIR/OrbitBarCore.o")
else
    MODULE_DIR="$BIN_DIR/Modules"
    CORE_OBJECTS=("$BIN_DIR/OrbitBarCore.build/"*.o)
fi
swiftc -swift-version 6 -parse-as-library -I "$MODULE_DIR" \
    Sources/OrbitBar/AppSettings.swift Sources/OrbitBar/IconRenderer.swift Sources/OrbitBar/MenuBarIconView.swift \
    Sources/OrbitBar/VolumeAnimator.swift \
    Sources/OrbitBar/StatusAccessory.swift \
    scripts/render-preview.swift "${CORE_OBJECTS[@]}" \
    -o "$PROJECT_DIR/.build/OrbitBarPreview"
"$PROJECT_DIR/.build/OrbitBarPreview" "$PROJECT_DIR/previews"
