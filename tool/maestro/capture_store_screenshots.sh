#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_dir="$(cd "$script_dir/../.." && pwd)"
readonly simulator_id="${1:-$(xcrun simctl list devices booted -j | plutil -extract devices raw -o - - | sed -n 's/.*"udid" : "\([^"]*\)".*/\1/p' | head -1)}"

if [[ -z "$simulator_id" ]]; then
  echo "No booted iOS Simulator found." >&2
  exit 1
fi
if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro is required. Install it with: brew install mobile-dev-inc/tap/maestro" >&2
  exit 1
fi

java_home="${JAVA_HOME:-}"
if [[ ! -x "$java_home/bin/java" ]] && command -v brew >/dev/null 2>&1; then
  java_home="$(brew --prefix openjdk)/libexec/openjdk.jdk/Contents/Home"
fi
if [[ ! -x "$java_home/bin/java" ]]; then
  echo "JDK 17 or later is required to run Maestro." >&2
  exit 1
fi

capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/trickle-store-capture.XXXXXX")"
cleanup() {
  xcrun simctl status_bar "$simulator_id" clear >/dev/null 2>&1 || true
  command rm -rf "$capture_dir"
}
trap cleanup EXIT

xcrun simctl ui "$simulator_id" appearance dark
xcrun simctl ui "$simulator_id" content_size large
xcrun simctl status_bar "$simulator_id" clear
xcrun simctl status_bar "$simulator_id" override \
  --time 9:41 \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4

"$script_dir/seed_store_screenshot_data.sh" "$simulator_id"
(
  cd "$project_dir"
  JAVA_HOME="$java_home" maestro test \
    --udid "$simulator_id" \
    --test-output-dir "$capture_dir" \
    tool/maestro/capture_store_screenshots.yaml
)

readonly destination_dir="$project_dir/store/apple/screenshots"
for name in 01-home 02-podcast 03-episode 04-unread 05-reader; do
  source="$(find "$capture_dir" -type f -path "*/takeScreenshot/store/apple/screenshots/$name.png" -print -quit)"
  if [[ -z "$source" ]]; then
    echo "Maestro did not create $name.png." >&2
    exit 1
  fi
  dimensions="$(sips -g pixelWidth -g pixelHeight "$source" 2>/dev/null)"
  if [[ "$dimensions" != *"pixelWidth: 1320"* || "$dimensions" != *"pixelHeight: 2868"* ]]; then
    echo "$name.png is not 1320x2868." >&2
    exit 1
  fi
  cp "$source" "$destination_dir/$name.png"
done

echo "Updated the five copyright-safe App Store screenshots."
