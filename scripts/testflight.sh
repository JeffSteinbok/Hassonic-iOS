#!/bin/bash
# Archives a Release build and uploads it to TestFlight with the Apple ID
# signed in to Xcode.
#
# The build number is stamped as YYYYMMDD.HHmm (UTC): App Store Connect
# requires it to strictly increase and never lets it go back down, and a
# timestamp does that without anyone having to bump and merge project.yml
# first.
#
# The team comes from DEVELOPMENT_TEAM in Config/Local.xcconfig.
#
# Uploading reads the Xcode account from the keychain, so this has to run
# outside any shell sandbox.
set -euo pipefail

cd "$(dirname "$0")/.."

team_id="$(python3 scripts/build_settings.py DEVELOPMENT_TEAM)"
if [[ -z "$team_id" ]]; then
  echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig first (see Local.xcconfig.example)." >&2
  exit 1
fi

build_number="$(date -u +%Y%m%d.%H%M)"
work_dir="$(mktemp -d)"
archive_path="$work_dir/Hassonic-$build_number.xcarchive"
export_options="$work_dir/ExportOptions.plist"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>$team_id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "Building $build_number"

xcodegen generate

# Set on the command line rather than with agvtool, so the app and the widget
# extension get the same number without touching project.yml.
xcodebuild archive \
  -project Hassonic.xcodeproj \
  -scheme Hassonic \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$build_number"

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$work_dir/export" \
  -allowProvisioningUpdates

echo "Uploaded build $build_number. It shows up in TestFlight once App Store Connect finishes processing it."
