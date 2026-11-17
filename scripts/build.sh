#!/bin/zsh
# Builds Brim (Debug) and puts it at build/Brim.app — always the same place, so macOS
# permissions and launch-at-login stay attached to one app.
#
#   scripts/build.sh                 signed with your Apple Development identity (use this for real testing)
#   BRIM_SIGN=adhoc scripts/build.sh ad-hoc signed: no keychain prompt, but permissions won't stick between builds
set -euo pipefail
cd "${0:A:h}/.."

signing=()
if [[ "${BRIM_SIGN:-}" == "adhoc" ]]; then
  signing=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual)
fi

# A running copy would be replaced underneath itself, so quit it first.
pkill -x Brim 2>/dev/null && sleep 0.5 || true

xcodebuild -project Brim.xcodeproj -scheme Brim -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -quiet build "${signing[@]}"

rm -rf build/Brim.app
ditto build/DerivedData/Build/Products/Debug/Brim.app build/Brim.app
echo "Built build/Brim.app${BRIM_SIGN:+ ($BRIM_SIGN)}"
