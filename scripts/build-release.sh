#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Info.plist")"
release_dir="$project_root/Releases/komPX $version"
dmg="$project_root/Releases/komPX-$version-universal.dmg"
if [[ -e "$release_dir" || -e "$dmg" ]]; then
  echo "Release $version already exists locally. Move it aside before rebuilding." >&2
  exit 1
fi
xcodebuild -project "$project_root/komPX.xcodeproj" -scheme komPX -configuration Release \
  -derivedDataPath "$project_root/build" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
mkdir -p "$release_dir"
ditto "$project_root/build/Build/Products/Release/komPX.app" "$release_dir/komPX.app"
xattr -cr "$release_dir/komPX.app"
codesign --force --sign "${KOMPX_SIGNING_IDENTITY:--}" --options runtime \
  --entitlements "$project_root/komPX.entitlements" "$release_dir/komPX.app"
codesign --verify --deep --strict --verbose=2 "$release_dir/komPX.app"
architectures="$(lipo -archs "$release_dir/komPX.app/Contents/MacOS/komPX")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
ln -s /Applications "$release_dir/Applications"
hdiutil create -volname "komPX $version" -srcfolder "$release_dir" -format UDZO "$dmg"
(cd "$project_root/Releases" && shasum -a 256 "$(basename "$dmg")" > "komPX-$version-SHA256.txt")
echo "Release ready: $dmg"
