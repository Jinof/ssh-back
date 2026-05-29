#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${SSH_BACK_DIST_DIR:-$ROOT_DIR/.build/release-artifacts}"
VERSION="${SSH_BACK_RELEASE_VERSION:-}"
NOTARY_APPLE_ID="${SSH_BACK_NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${SSH_BACK_NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${SSH_BACK_NOTARY_PASSWORD:-}"
REQUIRE_NOTARIZATION="${SSH_BACK_REQUIRE_NOTARIZATION:-0}"

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

ARCHIVE_PATH="$DIST_DIR/ssh-back-${SAFE_VERSION}-macos.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
NOTARY_ARCHIVE_PATH="$DIST_DIR/ssh-back-${SAFE_VERSION}-notary-upload.zip"

NOTARY_ENABLED=0
if [[ -n "$NOTARY_APPLE_ID$NOTARY_TEAM_ID$NOTARY_PASSWORD" ]]; then
  if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_TEAM_ID" || -z "$NOTARY_PASSWORD" ]]; then
    echo "Notarization requires SSH_BACK_NOTARY_APPLE_ID, SSH_BACK_NOTARY_TEAM_ID, and SSH_BACK_NOTARY_PASSWORD." >&2
    exit 1
  fi
  if [[ -z "${SSH_BACK_CODESIGN_IDENTITY:-}" || "${SSH_BACK_CODESIGN_IDENTITY:-}" == "-" ]]; then
    echo "Notarization requires SSH_BACK_CODESIGN_IDENTITY to be a Developer ID Application identity." >&2
    exit 1
  fi
  NOTARY_ENABLED=1
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" && "$NOTARY_ENABLED" != "1" ]]; then
  echo "Notarization is required. Set SSH_BACK_NOTARY_APPLE_ID, SSH_BACK_NOTARY_TEAM_ID, SSH_BACK_NOTARY_PASSWORD, and SSH_BACK_CODESIGN_IDENTITY." >&2
  exit 1
fi

APP_DIR="$("$ROOT_DIR/scripts/build-app-bundle.sh" | tail -n 1)"
if [[ ! -d "$APP_DIR" ]]; then
  echo "Expected app bundle at $APP_DIR, but it was not created." >&2
  exit 1
fi

if [[ "$NOTARY_ENABLED" == "1" ]]; then
  rm -f "$NOTARY_ARCHIVE_PATH"
  ditto -c -k --norsrc --keepParent "$APP_DIR" "$NOTARY_ARCHIVE_PATH"
  xcrun notarytool submit "$NOTARY_ARCHIVE_PATH" \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" \
    --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  rm -f "$NOTARY_ARCHIVE_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

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
