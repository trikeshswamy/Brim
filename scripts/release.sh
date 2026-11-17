#!/bin/zsh
# Makes what users download: build/release/Brim-<version>.dmg, a Brim.dmg copy, and their .sha256 files.
#   1. A Release build (no debug tools inside), built unsigned.
#   2. Signed with your "Brim Open Source" certificate (self-signed, 2026-10-07), or with the identity named by
#      BRIM_RELEASE_IDENTITY (a Developer ID, if you ever join Apple's program): a stable signature, so macOS keeps
#      Brim's permissions across updates. Hardened runtime on; only Config/Brim.entitlements, so no developer-only
#      permission (get-task-allow) slips in.
#   3. A disk image with Brim and a shortcut to Applications, signed too, and its SHA-256 so anyone can check the
#      download is the one you published.
#   4. build/release/appcast.xml for in-app updates (Sparkle): the disk image signed with the EdDSA key in your
#      keychain (made once with Sparkle's generate_keys; it never leaves this Mac). Attach appcast.xml and the .dmg to
#      the release tagged v<version> on the public repo: Brim reads releases/latest/download/appcast.xml.
# Run it in the public copy (scripts/export-public.sh), so private parts stay out.
set -euo pipefail
cd "${0:A:h}/.."
identity="${BRIM_RELEASE_IDENTITY:-Brim Open Source}"
security find-identity -p codesigning | grep -qF "\"$identity\"" \
  || { echo "✘ No \"$identity\" certificate in your keychain: import your backup (Certificates.p12) first."; exit 1; }
# Apple's timestamp server only stamps Apple-issued certificates; a self-signed one signs without it.
if [[ "$identity" == Developer\ ID\ Application:* ]]; then timestamp=(--timestamp); else timestamp=(--timestamp=none); fi

echo "▸ Release build"
xcodebuild -project Brim.xcodeproj -scheme Brim -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ReleaseData -quiet build CODE_SIGNING_ALLOWED=NO
built=build/ReleaseData/Build/Products/Release/Brim.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Contents/Info.plist")

echo "▸ Signing Brim $version"
mkdir -p build/release/stage
rm -rf build/release/stage/Brim.app
ditto "$built" build/release/stage/Brim.app
app=build/release/stage/Brim.app
# The licenses of what's inside travel with the app, as they ask (MIT: "shall be included in all copies"; BSD:
# "reproduce ... in the documentation and/or other materials"): Brim, Sparkle, mediaremote-adapter (2026-11-17).
licenses="$app/Contents/Resources/Licenses"
mkdir -p "$licenses"
cp LICENSE "$licenses/Brim.txt"
cp build/ReleaseData/SourcePackages/artifacts/sparkle/Sparkle/LICENSE "$licenses/Sparkle.txt"
cp Vendor/MediaRemoteAdapter/LICENSE "$licenses/mediaremote-adapter.txt"
# Sparkle's helpers first, inside out (Sparkle's documented order), each with our identity and hardened runtime.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$sparkle" ]]; then
  codesign --force --options runtime "${timestamp[@]}" -s "$identity" "$sparkle/XPCServices/Installer.xpc"
  codesign --force --options runtime "${timestamp[@]}" --preserve-metadata=entitlements -s "$identity" "$sparkle/XPCServices/Downloader.xpc"
  codesign --force --options runtime "${timestamp[@]}" -s "$identity" "$sparkle/Autoupdate"
  codesign --force --options runtime "${timestamp[@]}" -s "$identity" "$sparkle/Updater.app"
fi
for framework in "$app"/Contents/Frameworks/*.framework(N); do
  codesign --force --options runtime "${timestamp[@]}" -s "$identity" "$framework"
done
codesign --force --options runtime "${timestamp[@]}" --entitlements Config/Brim.entitlements -s "$identity" "$app"
codesign --verify --strict --deep "$app"
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then
  echo "✘ The developer-only permission is still in: not a release."; exit 1
fi

echo "▸ Disk image"
ln -sfn /Applications build/release/stage/Applications
dmg=build/release/Brim-$version.dmg
hdiutil create -quiet -volname "Brim $version" -srcfolder build/release/stage -ov -format UDZO "$dmg"
codesign --force "${timestamp[@]}" -s "$identity" "$dmg"
(cd build/release && shasum -a 256 "Brim-$version.dmg" > "Brim-$version.dmg.sha256")
echo "✓ $dmg"
cat "$dmg.sha256"

echo "▸ Appcast (in-app updates)"
tools=build/ReleaseData/SourcePackages/artifacts/sparkle/Sparkle/bin
# A folder per version, so the appcast lists only this release (and a test run's leftovers never slip in).
updates=build/release/updates-$version
mkdir -p "$updates"
cp "$dmg" "$updates/"
"$tools/generate_appcast" --download-url-prefix "https://github.com/trikeshswamy/Brim/releases/download/v$version/" \
  -o build/release/appcast.xml "$updates"
# The same disk image under a name that never changes, so the site's Download button can always point to
# releases/latest/download/Brim.dmg (a versioned name can't be "latest").
cp "$dmg" build/release/Brim.dmg
(cd build/release && shasum -a 256 Brim.dmg > Brim.dmg.sha256)
echo "✓ Attach to the release v$version: build/release/appcast.xml, Brim.dmg, Brim.dmg.sha256, $dmg"
