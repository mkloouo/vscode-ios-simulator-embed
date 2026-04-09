#!/usr/bin/env bash
# Links CoreSimulator + SimulatorKit from the active Xcode / system paths.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
DEV="$(xcode-select -p)"
exec swift build -c release \
  -Xlinker -F -Xlinker /Library/Developer/PrivateFrameworks \
  -Xlinker -F -Xlinker "$DEV/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker /Library/Developer/PrivateFrameworks \
  -Xlinker -rpath -Xlinker "$DEV/Library/PrivateFrameworks" \
  -Xlinker -framework -Xlinker CoreSimulator \
  -Xlinker -framework -Xlinker SimulatorKit \
  "$@"
