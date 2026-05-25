#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${SSH_BACK_DIST_DIR:-$ROOT_DIR/.build/release-artifacts}"
VERSION="${SSH_BACK_RELEASE_VERSION:-}"

if [[ -z "$VERSION" ]]; then
  if VERSION_FROM_TAG="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null)"; then
    VERSION="$VERSION_FROM_TAG"
  elif SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null)"; then
    VERSION="$SOURCE_SHA"
  else
    VERSION="$(date -u +%Y%m%d%H%M%S)"
  fi
fi

SAFE_VERSION="$(printf '%s' "$VERSION" | tr '/[:space:]' '--' | tr -cd 'A-Za-z0-9._-')"
if [[ -z "$SAFE_VERSION" ]]; then
  echo "Unable to derive a safe release version from '$VERSION'." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"

APP_DIR="$("$ROOT_DIR/scripts/build-app-bundle.sh" | tail -n 1)"
if [[ ! -d "$APP_DIR" ]]; then
  echo "Expected app bundle at $APP_DIR, but it was not created." >&2
  exit 1
fi

ARCHIVE_PATH="$DIST_DIR/ssh-back-${SAFE_VERSION}-macos.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

(
  cd "$(dirname "$ARCHIVE_PATH")"
  shasum -a 256 "$(basename "$ARCHIVE_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf 'app_path=%s\n' "$APP_DIR"
printf 'archive_path=%s\n' "$ARCHIVE_PATH"
printf 'checksum_path=%s\n' "$CHECKSUM_PATH"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'app_path=%s\n' "$APP_DIR"
    printf 'archive_path=%s\n' "$ARCHIVE_PATH"
    printf 'checksum_path=%s\n' "$CHECKSUM_PATH"
    printf 'version=%s\n' "$VERSION"
  } >> "$GITHUB_OUTPUT"
fi
