#!/bin/bash
# Run the visionOS simulator build on this Mac against the Mac install's game data (no copy: the
# app's Documents/data/{game,update,user} are symlinks into the game folder; simulator apps are Mac
# processes). Builds the simulator app first (make_app.sh with XROS_SIM=1).
#   GTAV_GAME_DYLIB=<simulator gtav_game.dylib> tools/visionos/run_sim.sh [extra args...]
# The game log is <container>/Documents/logs/gtav.log (printed below); the console goes to stdout.
# Note: data/user is shared with the Mac install (profile, settings, saves).
set -euo pipefail
# Personal settings (TEAM_ID, BUNDLE_ID, GTAV_XROS_DEVICE): tools/visionos/local.env, git-ignored.
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"
R="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:?set BUNDLE_ID or put it in tools/visionos/local.env}"
SIM_NAME="${XROS_SIM_DEVICE:-Apple Vision Pro}"
H="${GTAV_HOME:-$(defaults read io.github.gtav-recomp GameFolder)}"
APP="${GTAV_XROS_SIM_APP:-$R/build/xrsim-package/GTAV.app}"

XROS_SIM=1 GTAV_XROS_APP="$APP" GTAV_SPIRV="$H/data/spirv" "$R/tools/visionos/make_app.sh"

state=$(xcrun simctl list devices | grep -F "$SIM_NAME (" | head -1)
if ! echo "$state" | grep -q Booted; then xcrun simctl boot "$SIM_NAME"; fi
open "$(xcode-select -p)/Applications/Simulator.app" || true
xcrun simctl install booted "$APP"
DOCS="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)/Documents"
mkdir -p "$DOCS/data" "$DOCS/logs"
for p in game update user; do ln -sfn "$H/data/$p" "$DOCS/data/$p"; done
echo "game log: $DOCS/logs/gtav.log"
xcrun simctl launch --console-pty --terminate-running-process booted "$BUNDLE_ID" "$@"
