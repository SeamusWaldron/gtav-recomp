#!/bin/bash
# Mint (or refresh) the development provisioning profile for the visionOS app: Xcode registers the
# explicit App ID with the kernel entitlements and downloads a profile covering the team's devices.
# Needs Xcode signed in to the team's Apple account. Profiles land in
# ~/Library/Developer/Xcode/UserData/Provisioning Profiles; make_app.sh finds it by App ID.
#   TEAM_ID=... BUNDLE_ID=... tools/visionos/mint_profile.sh
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
export TEAM_ID="${TEAM_ID:?set TEAM_ID (the OU of your Apple Development certificate)}"
export BUNDLE_ID="${BUNDLE_ID:?set BUNDLE_ID}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp -R "$R/tools/visionos/profile/." "$W/"
(cd "$W" && xcodegen generate --quiet)
xcodebuild -project "$W/GTAVProfile.xcodeproj" -target GTAVProfile -sdk xros -configuration Debug \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration SYMROOT="$W/build" build | tail -5
