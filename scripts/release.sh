#!/usr/bin/env bash
# Bump package.json version (git commit + tag), then build a VSIX via vsce.
# Usage:
#   npm run release -- patch|minor|major
#   npm run release -- 1.2.3
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "Usage: $0 patch|minor|major" >&2
  echo "       $0 X.Y.Z    (exact semver)" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
ARG="$1"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "release: not a git repository." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "release: working tree is not clean. Commit or stash first." >&2
  exit 1
fi

NATIVE="$ROOT/native/ios-sim-helper/.build/release/ios-sim-helper"
if [[ ! -f "$NATIVE" ]]; then
  echo "release: native helper missing at $NATIVE" >&2
  echo "release: run: npm run build:native" >&2
  exit 1
fi

case "$ARG" in
  patch | minor | major)
    npm version "$ARG" -m "chore(release): %s"
    ;;
  *)
    if [[ "$ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      npm version "$ARG" -m "chore(release): %s"
    else
      usage
    fi
    ;;
esac

npx --yes @vscode/vsce package

VER="$(node -p "require('./package.json').version")"
echo ""
echo "release: created tag v${VER} and ios-simulator-embed-${VER}.vsix"
