#!/bin/bash
# Builds a Developer ID signed, notarized, stapled release into build/Release.
#
# Needs a "Developer ID Application" certificate for team F68K4R5G38 in the
# keychain, and notarytool credentials stored under the profile name below:
#   xcrun notarytool store-credentials synthwave-notary --apple-id <id> --team-id F68K4R5G38
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-synthwave-notary}"
OUT=build/Release
ARCHIVE=build/Synthwave-Visualizer.xcarchive
APP="$OUT/Synthwave-Visualizer.app"
ZIP="$OUT/Synthwave-Visualizer.zip"

rm -rf "$OUT" "$ARCHIVE"

xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist Config/ExportOptions.plist -exportPath "$OUT" \
    -allowProvisioningUpdates

# notarytool takes a zip; the ticket is then stapled to the app, and the
# distributable zip is rebuilt so it carries the stapled app.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl -a -vv "$APP"
echo "Release: $ZIP"
