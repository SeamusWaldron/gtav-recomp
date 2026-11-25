#!/bin/bash
# Copy the Mac install's checked game data into the visionOS app's Documents (dev builds; the app
# must be installed first). About 15 GB over the network, once; later runs can skip folders.
#   tools/visionos/push_data.sh [game] [update] [user]      (default: all three)
#   GTAV_HOME  the Mac game folder (default: the GTAV.app setting)
set -euo pipefail
# Personal settings (TEAM_ID, BUNDLE_ID, GTAV_XROS_DEVICE): tools/visionos/local.env, git-ignored.
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"
BUNDLE_ID="${BUNDLE_ID:?set BUNDLE_ID or put it in tools/visionos/local.env}"
DEVICE="${GTAV_XROS_DEVICE:?set GTAV_XROS_DEVICE (xcrun devicectl list devices)}"
H="${GTAV_HOME:-$(defaults read io.github.gtav-recomp GameFolder)}"
[ -f "$H/data/installed.txt" ] || { echo "no installed game in $H"; exit 1; }
parts=("$@"); [ ${#parts[@]} -gt 0 ] || parts=(game update user)
for p in "${parts[@]}"; do
  echo "copying data/$p ($(du -sh "$H/data/$p" | cut -f1))..."
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "$H/data/$p" --destination "Documents/data/$p"
done
