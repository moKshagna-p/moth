#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
cargo build --release

bundle="target/release/Moth.app"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
cp target/release/moth "$bundle/Contents/MacOS/Moth"
cp assets/Moth.icns "$bundle/Contents/Resources/Moth.icns"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Moth</string>
  <key>CFBundleIdentifier</key><string>dev.mokshagna.moth</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Moth</string>
  <key>CFBundleIconFile</key><string>Moth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web links</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
  </dict></array>
  <key>NSCameraUsageDescription</key><string>Websites can request camera access after you approve.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites can request microphone access after you approve.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$bundle/Contents/Info.plist"
if [ -n "${MOTH_SIGNING_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$MOTH_SIGNING_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --strict "$bundle"
if [ -n "${MOTH_NOTARY_PROFILE:-}" ]; then
  test -n "${MOTH_SIGNING_IDENTITY:-}" || { echo "Notarization requires MOTH_SIGNING_IDENTITY" >&2; exit 1; }
  ditto -c -k --keepParent "$bundle" target/release/Moth-notarize.zip
  xcrun notarytool submit target/release/Moth-notarize.zip --keychain-profile "$MOTH_NOTARY_PROFILE" --wait
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
fi
ditto -c -k --keepParent "$bundle" target/release/Moth.zip
echo "Built $bundle and target/release/Moth.zip"
