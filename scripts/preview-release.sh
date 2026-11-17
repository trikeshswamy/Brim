#!/bin/zsh
# Makes a clearly labeled, unsigned Developer Preview for a few testers.
# This is not a production release: it is not notarized and will trigger macOS Gatekeeper warnings.
# Run this in the sanitized public copy created by scripts/export-public.sh before sharing it.
set -euo pipefail
cd "${0:A:h}/.."

echo "▸ Building unsigned Developer Preview"
xcodebuild -project Brim.xcodeproj -scheme Brim -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/PreviewData -quiet build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

built=build/PreviewData/Build/Products/Release/Brim.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Contents/Info.plist")
preview=build/preview
stage="$preview/stage"
zip="$preview/Brim-$version-Developer-Preview.zip"

mkdir -p "$preview"
rm -rf "$stage"
rm -f "$zip" "$zip.sha256"
mkdir -p "$stage"
ditto "$built" "$stage/Brim.app"
ditto -c -k --sequesterRsrc --keepParent "$stage/Brim.app" "$zip" >/dev/null
shasum -a 256 "$zip" > "$zip.sha256"
rm -rf "$stage"

echo "✓ Unsigned Developer Preview: $zip"
echo "✓ SHA-256: $zip.sha256"
echo "⚠ This build is not notarized. Share it only with testers who understand the manual Gatekeeper step."
