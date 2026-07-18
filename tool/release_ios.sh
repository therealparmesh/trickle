#!/usr/bin/env bash
set -euo pipefail

mode="${1:-build}"
case "$mode" in
  build | upload) ;;
  *)
    echo "Usage: tool/release_ios.sh [build|upload]" >&2
    exit 64
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
started_at="$(date +%s)"

cd "$root"

if [[ "$mode" == "upload" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Refusing to upload from a dirty working tree. Commit the release first." >&2
    exit 1
  fi
fi

flutter pub get
if ! command -v oxfmt >/dev/null 2>&1; then
  echo "Missing oxfmt; install version 0.57.0 or later." >&2
  exit 1
fi
oxfmt --check README.md 'docs/**/*.md' 'store/**/*.md'
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build ipa \
  --release \
  --export-options-plist="$root/store/apple/AppStoreExportOptions.plist"

ipa="$(find "$root/build/ios/ipa" -maxdepth 1 -type f -name '*.ipa' -print -quit 2>/dev/null || true)"
if [[ -z "$ipa" || "$(stat -f %m "$ipa")" -lt "$started_at" ]]; then
  echo "No fresh App Store IPA was exported." >&2
  exit 1
fi

if [[ "$mode" == "upload" ]]; then
  key_id="${APP_STORE_CONNECT_KEY_ID:-DC6F5JMNM3}"
  issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-19bebb70-4123-40d3-9379-1476fcc51b60}"
  key_dir="${API_PRIVATE_KEYS_DIR:-$HOME/.appstoreconnect/private_keys}"

  if [[ ! -f "$key_dir/AuthKey_$key_id.p8" ]]; then
    echo "Missing App Store Connect key: $key_dir/AuthKey_$key_id.p8" >&2
    exit 1
  fi

  xcrun altool --validate-app \
    --file "$ipa" \
    --type ios \
    --apiKey "$key_id" \
    --apiIssuer "$issuer_id"
  xcrun altool --upload-app \
    --file "$ipa" \
    --type ios \
    --apiKey "$key_id" \
    --apiIssuer "$issuer_id"
fi
