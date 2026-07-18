set -eu

# background_downloader ships one manifest for every optional feature, including
# copying user-selected photos. trickle only downloads podcast audio into its
# private Application Support directory and never invokes Photo Library APIs.
app_root="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
manifests="$(find "$app_root" -path '*background_downloader*' -name PrivacyInfo.xcprivacy -type f 2>/dev/null)"

if [ -z "$manifests" ]; then
  echo "error: background_downloader privacy manifest was not found in ${app_root}" >&2
  exit 1
fi

while IFS= read -r manifest; do
  if collected="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$manifest" 2>/dev/null)"; then
    type_count="$(printf '%s\n' "$collected" | awk '/NSPrivacyCollectedDataType =/ { count++ } END { print count + 0 }')"
    if [ "$type_count" -ne 1 ] || ! printf '%s\n' "$collected" | grep -q 'NSPrivacyCollectedDataType = NSPrivacyCollectedDataTypePhotosOrVideos'; then
      echo "error: background_downloader declares unexpected collected data in ${manifest}" >&2
      exit 1
    fi
    /usr/libexec/PlistBuddy -c 'Delete :NSPrivacyCollectedDataTypes' "$manifest"
  fi
  if /usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$manifest" >/dev/null 2>&1; then
    echo "error: failed to remove the unused Photos or Videos declaration from ${manifest}" >&2
    exit 1
  fi
done <<EOF
$manifests
EOF
