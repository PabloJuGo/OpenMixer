#!/bin/sh
# Builds a native (Apple silicon) OpenMixer.app and packages it as a .dmg and a .zip with SHA-256 sums in build/release/.
# Usage: scripts/release.sh
set -e
cd "$(dirname "$0")/.."
scripts/bundle.sh   # arm64 only: macOS 28 no longer runs Intel code, so no x86_64 slice is shipped
version=$(defaults read "$PWD/build/OpenMixer.app/Contents/Info" CFBundleShortVersionString)
out=build/release
rm -rf "$out" && mkdir -p "$out/dmg"
cp -R build/OpenMixer.app "$out/dmg/"
ln -s /Applications "$out/dmg/Applications"
name="OpenMixer-$version"
hdiutil create -quiet -volname "OpenMixer" -srcfolder "$out/dmg" -ov -format UDZO "$out/$name.dmg"
ditto -c -k --keepParent build/OpenMixer.app "$out/$name.zip"
rm -rf "$out/dmg"
(cd "$out" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
