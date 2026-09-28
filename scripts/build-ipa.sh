#!/bin/sh
# Builds an unsigned Release build/Reel.ipa for SideStore, which re-signs it
# with your own Apple ID when it installs.
set -eu
cd "$(dirname "$0")/.."

rm -rf build/Reel.xcarchive build/Payload build/Reel.ipa
xcodebuild archive \
  -project Reel.xcodeproj -scheme Reel -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Reel.xcarchive \
  -clonedSourcePackagesDirPath .spm \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  "$@"

mkdir build/Payload
cp -R build/Reel.xcarchive/Products/Applications/Reel.app build/Payload/
(cd build && zip -qry Reel.ipa Payload)
rm -rf build/Payload
echo "Built $(pwd)/build/Reel.ipa ($(du -h build/Reel.ipa | cut -f1))"
