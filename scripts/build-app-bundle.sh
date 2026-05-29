#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/release/SSH Back.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGN_IDENTITY="${SSH_BACK_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

cd "$ROOT_DIR"
swift build -c release --product ssh-back-menubar

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/ssh-back-menubar" "$CONTENTS_DIR/MacOS/ssh-back-menubar"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod 755 "$CONTENTS_DIR/MacOS/ssh-back-menubar"

if [[ "${SSH_BACK_SKIP_CODESIGN:-}" != "1" ]]; then
  CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
  fi

  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

echo "$APP_DIR"
