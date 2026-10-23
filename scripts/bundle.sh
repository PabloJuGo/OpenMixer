#!/bin/sh
# Builds build/OpenMixer.app (release, ad-hoc signed). Usage: scripts/bundle.sh [--install]
# UNIVERSAL=1 also builds an Intel slice (for macOS 14-27 on Intel Macs; macOS 28 won't run it).
set -e
cd "$(dirname "$0")/.."
# SwiftPM's multi-arch mode needs full Xcode, so universal builds compile each slice and lipo them together.
if [ -n "$UNIVERSAL" ]; then
  for arch in arm64 x86_64; do swift build -c release --product OpenMixer --triple "$arch-apple-macosx14.2"; done
  mkdir -p build && lipo -create -output build/OpenMixer-universal \
    "$(swift build -c release --triple arm64-apple-macosx14.2 --show-bin-path)/OpenMixer" \
    "$(swift build -c release --triple x86_64-apple-macosx14.2 --show-bin-path)/OpenMixer"
  binary=build/OpenMixer-universal
else
  swift build -c release --product OpenMixer
  binary="$(swift build -c release --show-bin-path)/OpenMixer"
fi
app=build/OpenMixer.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp "$binary" "$app/Contents/MacOS/OpenMixer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OpenMixer</string>
  <key>CFBundleIdentifier</key><string>org.openmixer.OpenMixer</string>
  <key>CFBundleName</key><string>OpenMixer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>OpenMixer captures an app's audio to change its volume, EQ and output device.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>OpenMixer connects and disconnects your Bluetooth audio devices.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
# Login items work best from /Applications: scripts/bundle.sh --install
if [ "$1" = "--install" ]; then rm -rf /Applications/OpenMixer.app && cp -R "$app" /Applications/ && echo "Installed /Applications/OpenMixer.app"; fi
