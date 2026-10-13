#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="OrbitBar"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-macos.zip"
BUILD_ARGS=(--configuration release --product "$APP_NAME")

case "${1:-}" in
  "") ;;
  --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
  -h|--help)
    echo "Usage: $0 [--universal]"
    echo "Build an ad-hoc signed macOS app and ZIP in the project's dist directory."
    exit 0
    ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--universal]" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "OrbitBar must be built on macOS with the Xcode command-line tools." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
# The open descriptor keeps the BSD lock alive for this shell and its children.
# Keep the lock inode between runs; unlinking it would permit competing locks.
exec 9>>"$DIST_DIR/.$APP_NAME.build.lock"
if ! /usr/bin/lockf -s -t 0 9; then
  echo "Another OrbitBar build is using this dist directory. Try again after it finishes." >&2
  exit 1
fi

# A stable journal directory lets the next build recover an interrupted swap,
# including a SIGKILL between a rename and the shell's next instruction.
STAGING_DIR="$DIST_DIR/.$APP_NAME.release"
COMMIT_MARKER="$DIST_DIR/.$APP_NAME.release-committed"
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
STAGED_ZIP="$STAGING_DIR/$APP_NAME-macos.zip"
APP_BACKUP="$STAGING_DIR/previous.app"
ZIP_BACKUP="$STAGING_DIR/previous.zip"

# Check both the recorded launch path and the executable inode, so launching a
# symlink to this bundle cannot evade the replacement guard. Fail closed if ps
# is unavailable rather than interpreting an unreadable process list as empty.
destination_is_running() {
  local executable process_list
  process_list="$(ps -axo comm=)" || return 2
  while IFS= read -r executable; do
    if [[ "$executable" == "$APP_DIR/Contents/MacOS/$APP_NAME" ||
          "$executable" -ef "$APP_DIR/Contents/MacOS/$APP_NAME" ]]; then return 0; fi
  done <<< "$process_list"
  return 1
}

require_destination_stopped() {
  local status=0
  destination_is_running || status=$?
  case "$status" in
    0) echo "Quit the OrbitBar app in dist before replacing it, then run this build again." >&2; return 1 ;;
    1) return 0 ;;
    *) echo "Unable to check running applications; the existing release was left unchanged." >&2; return 1 ;;
  esac
}

recover_release() {
  if [[ ! -d "$STAGING_DIR" ]]; then
    rm -f "$COMMIT_MARKER" || return 1
    return 0
  fi
  if [[ -e "$STAGING_DIR/publishing" && ! -e "$COMMIT_MARKER" && ! -e "$STAGING_DIR/committed" ]]; then
    # Backup presence is authoritative: it survives interruptions between a
    # rename and any shell bookkeeping, and recovery can itself be retried.
    if [[ -e "$APP_BACKUP" || -L "$APP_BACKUP" ]]; then
      rm -rf "$APP_DIR" || return 1
      mv "$APP_BACKUP" "$APP_DIR" || return 1
    elif [[ -e "$STAGING_DIR/app-was-absent" ]]; then
      rm -rf "$APP_DIR" || return 1
    fi
    if [[ -e "$ZIP_BACKUP" || -L "$ZIP_BACKUP" ]]; then
      rm -f "$ZIP_PATH" || return 1
      mv "$ZIP_BACKUP" "$ZIP_PATH" || return 1
    elif [[ -e "$STAGING_DIR/zip-was-absent" ]]; then
      rm -f "$ZIP_PATH" || return 1
    fi
  fi
  # Keep the commit record outside this directory until cleanup is complete.
  # A SIGKILL during recursive deletion must never turn a committed pair into
  # an apparent incomplete publication with only one old backup remaining.
  rm -rf "$STAGING_DIR" || return 1
  rm -f "$COMMIT_MARKER"
}

require_destination_stopped
if ! recover_release; then
  echo "Unable to recover the previous release; backups remain in $STAGING_DIR" >&2
  exit 1
fi

cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e
  if ! recover_release; then
    echo "Unable to restore the previous release; recover the backup from $STAGING_DIR" >&2
    if [[ "$exit_status" == 0 ]]; then exit_status=1; fi
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

cd "$PROJECT_DIR"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

# Never modify a valid previous release until every staged artifact is checked.
mkdir -p "$STAGING_DIR"

ICONSET_DIR="$STAGING_DIR/OrbitBar.iconset"
mkdir -p "$ICONSET_DIR"
swift "$PROJECT_DIR/scripts/generate-icon.swift" "$ICONSET_DIR"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
iconutil --convert icns "$ICONSET_DIR" --output "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/$APP_NAME" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
chmod +x "$STAGED_APP/Contents/MacOS/$APP_NAME"

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$STAGED_APP/Contents/Info.plist" >/dev/null
plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$STAGED_APP" "$STAGED_ZIP"
unzip -tq "$STAGED_ZIP"

require_destination_stopped

# Write the journal before touching either destination. A committed marker is
# created only when both new artifacts are in place; otherwise recovery rolls
# back the pair using the filesystem, without depending on in-memory flags.
if [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" ]]; then : > "$STAGING_DIR/app-was-absent"; fi
if [[ ! -e "$ZIP_PATH" && ! -L "$ZIP_PATH" ]]; then : > "$STAGING_DIR/zip-was-absent"; fi
: > "$STAGING_DIR/publishing"
if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
  mv "$APP_DIR" "$APP_BACKUP"
fi
if [[ -e "$ZIP_PATH" || -L "$ZIP_PATH" ]]; then
  mv "$ZIP_PATH" "$ZIP_BACKUP"
fi
mv "$STAGED_APP" "$APP_DIR"
mv "$STAGED_ZIP" "$ZIP_PATH"
: > "$COMMIT_MARKER"
echo "Built: $APP_DIR"
echo "ZIP:   $ZIP_PATH"
echo "This local build uses ad-hoc signing; it is not Apple-notarized."
