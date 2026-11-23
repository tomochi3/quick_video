#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$project_dir/build"
output_app="$build_dir/倍速メーカー.app"
stage="$(mktemp -d "${TMPDIR:-/tmp}/quick-video.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
stage_app="$stage/倍速メーカー.app"

mkdir -p "$stage_app/Contents/MacOS" "$build_dir"
cp "$project_dir"/Sources/{App.swift,Video.swift} "$stage/"
cp "$project_dir/Sources/Info.plist" "$stage_app/Contents/Info.plist"

xcrun swiftc -swift-version 5 -O \
  -module-cache-path "$stage/module-cache" \
  -target "$(uname -m)-apple-macos15.0" \
  "$stage/App.swift" "$stage/Video.swift" \
  -o "$stage_app/Contents/MacOS/SpeedMaker"

codesign --force --sign - "$stage_app"
codesign --verify --strict "$stage_app"

rm -rf -- "$output_app"
ditto --norsrc "$stage_app" "$output_app"
codesign --verify --strict "$output_app"
printf 'Built %s\n' "$output_app"
