#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

bundle="target/release/Moth.app"
test -d "$bundle" || { echo "Run scripts/build-app.sh first" >&2; exit 1; }
codesign --verify --strict "$bundle"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$bundle/Contents/Info.plist")
architecture=$(uname -m)
output="target/release/Moth-${version}-macOS-${architecture}.dmg"
stage=$(mktemp -d "${TMPDIR:-/tmp}/moth-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
ditto "$bundle" "$stage/Moth.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Moth Beta" -srcfolder "$stage" -format UDZO -ov "$output"
hdiutil verify "$output"
(cd target/release && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
echo "Built $output"
