#!/usr/bin/env bash
# Copies the release ios-sim-helper into native/ios-sim-helper/dist/ for VSIX packaging
# (.vscodeignore excludes SwiftPM .build, which is huge).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/ios-sim-helper/.build/release/ios-sim-helper"
DST_DIR="$ROOT/native/ios-sim-helper/dist"
if [[ ! -f "$SRC" ]]; then
  echo "stage-native-helper: missing $SRC — run: npm run build:native" >&2
  exit 1
fi
mkdir -p "$DST_DIR"
cp "$SRC" "$DST_DIR/ios-sim-helper"
chmod +x "$DST_DIR/ios-sim-helper"
echo "Staged $DST_DIR/ios-sim-helper"
