#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

render_svg() {
  source="$1"
  input="$work/$(basename "$source")"
  cp "$source" "$input"
  qlmanage -t -s 1024 -o "$work" "$input" >/dev/null 2>&1
  printf '%s/%s.png' "$work" "$(basename "$source")"
}

render_transparent_svg() {
  source="$1"
  output="$work/$(basename "$source").png"
  sips -s format png "$source" --out "$output" >/dev/null
  printf '%s' "$output"
}

resize() {
  source="$1"
  size="$2"
  destination="$3"
  sips -z "$size" "$size" "$source" --out "$destination" >/dev/null
}

swiftc "$root/tool/flatten_png.swift" -o "$work/flatten_png"

resize_opaque() {
  source="$1"
  size="$2"
  destination="$3"
  "$work/flatten_png" "$source" "$destination" "$size"
}

mark="$(render_svg "$root/assets/brand/trickle-mark.svg")"
launch="$(render_transparent_svg "$root/assets/brand/trickle-launch.svg")"
ios="$root/ios/Runner/Assets.xcassets/AppIcon.appiconset"

resize_opaque "$mark" 1024 "$ios/Icon-App-1024x1024@1x.png"
resize_opaque "$mark" 20 "$ios/Icon-App-20x20@1x.png"
resize_opaque "$mark" 40 "$ios/Icon-App-20x20@2x.png"
resize_opaque "$mark" 60 "$ios/Icon-App-20x20@3x.png"
resize_opaque "$mark" 29 "$ios/Icon-App-29x29@1x.png"
resize_opaque "$mark" 58 "$ios/Icon-App-29x29@2x.png"
resize_opaque "$mark" 87 "$ios/Icon-App-29x29@3x.png"
resize_opaque "$mark" 40 "$ios/Icon-App-40x40@1x.png"
resize_opaque "$mark" 80 "$ios/Icon-App-40x40@2x.png"
resize_opaque "$mark" 120 "$ios/Icon-App-40x40@3x.png"
resize_opaque "$mark" 120 "$ios/Icon-App-60x60@2x.png"
resize_opaque "$mark" 180 "$ios/Icon-App-60x60@3x.png"
resize_opaque "$mark" 76 "$ios/Icon-App-76x76@1x.png"
resize_opaque "$mark" 152 "$ios/Icon-App-76x76@2x.png"
resize_opaque "$mark" 167 "$ios/Icon-App-83.5x83.5@2x.png"

resize_opaque "$mark" 48 "$root/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
resize_opaque "$mark" 72 "$root/android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
resize_opaque "$mark" 96 "$root/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png"
resize_opaque "$mark" 144 "$root/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png"
resize_opaque "$mark" 192 "$root/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"
resize_opaque "$mark" 512 "$root/store/trickle-icon-512.png"

launch_set="$root/ios/Runner/Assets.xcassets/TrickleLaunchMark.imageset"
resize "$launch" 96 "$launch_set/TrickleLaunchMark.png"
resize "$launch" 192 "$launch_set/TrickleLaunchMark@2x.png"
resize "$launch" 288 "$launch_set/TrickleLaunchMark@3x.png"
