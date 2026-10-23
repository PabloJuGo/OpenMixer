#!/bin/sh
# End-to-end audio test: plays a quiet 440 Hz tone, then checks that a per-app tap silences, restores and scales it.
# Run it from Finder-visible context: macOS will ask once to allow "OpenMixer Check" to capture audio — click Allow.
set -e
cd "$(dirname "$0")/.."
swift build --product SelfCheck
app=build/OpenMixerCheck.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
cp "$(swift build --show-bin-path)/SelfCheck" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SelfCheck</string><key>CFBundleIdentifier</key><string>org.openmixer.SelfCheck</string>
<key>CFBundleName</key><string>OpenMixer Check</string><key>CFBundlePackageType</key><string>APPL</string>
<key>NSAudioCaptureUsageDescription</key><string>OpenMixer's self-check plays a quiet tone and measures it.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
rm -f /tmp/openmixer-live.log
open -W --stdout /tmp/openmixer-live.log --stderr /tmp/openmixer-live.log "$app" --args --live
cat /tmp/openmixer-live.log
