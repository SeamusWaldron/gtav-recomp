#!/bin/bash
# Assemble, sign and (optionally) install the visionOS dev build (docs/VISIONOS_PLAN.md).
#   GTAV_GAME_DYLIB=<gtav_game.dylib for xros> tools/visionos/make_app.sh [--install]
# Inputs: build/xros-shell (gtav_fast for visionOS, GTAV_GAME_DLL=ON), the visionOS SDK install
# (rexglue-sdk/out/install/xros-arm64) and its MoltenVK build, the player's game library
# (tools/game_dll/build_game_dll.py --visionos), the shaders translated on the Mac (GTAV_SPIRV,
# optional: copied into the app), and the profile minted by tools/visionos/mint_profile.sh.
# GTAV_BRIDGE=1 adds --bridge_url for this Mac (GTAV_BRIDGE_URL=<url> to set it, GTAV_BRIDGE_PREFETCH=1).
# DEV BUILD ONLY: the app contains the recompiled game code and its shaders; never publish it.
set -euo pipefail
# Personal settings (TEAM_ID, BUNDLE_ID, GTAV_XROS_DEVICE): tools/visionos/local.env, git-ignored.
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"
R="$(cd "$(dirname "$0")/../.." && pwd)"
TEAM_ID="${TEAM_ID:-}"  # needed for device signing (not the simulator)
BUNDLE_ID="${BUNDLE_ID:?set BUNDLE_ID or put it in tools/visionos/local.env}"
# XROS_SIM=1: the visionOS simulator on this Mac (simulator builds, ad-hoc signed, no profile).
SIM="${XROS_SIM:-0}"
if [ "$SIM" = 1 ]; then
  SDK="${GTAV_XROS_SDK:-$R/rexglue-sdk/out/install/xrsim-arm64}"
  SHELL_EXE="${GTAV_SHELL:-$R/build/xrsim-shell/gtav_fast.app/gtav_fast}"
  PLATFORM=XRSimulator
else
  SDK="${GTAV_XROS_SDK:-$R/rexglue-sdk/out/install/xros-arm64}"
  SHELL_EXE="${GTAV_SHELL:-$R/build/xros-shell/gtav_fast.app/gtav_fast}"
  PLATFORM=XROS
fi
MOLTENVK="${MOLTENVK_DYLIB:-$SDK/lib/libMoltenVK.dylib}"
GAME="${GTAV_GAME_DYLIB:?set GTAV_GAME_DYLIB to the visionOS gtav_game.dylib}"
APP="${GTAV_XROS_APP:-$R/build/xros-package/GTAV.app}"

rm -rf "$APP"; mkdir -p "$APP"
cp "$SHELL_EXE" "$APP/gtav"
cp "$GAME" "$APP/gtav_game.dylib"
cp "$SDK/lib/librexruntime.dylib" "$SDK/lib/librexgpu-xenos.dylib" "$APP/"
cp "$MOLTENVK" "$APP/libMoltenVK.dylib"
chmod u+w "$APP"/*.dylib
install_name_tool -id @rpath/libMoltenVK.dylib "$APP/libMoltenVK.dylib" 2>/dev/null
install_name_tool -add_rpath @executable_path "$APP/gtav" 2>/dev/null || true
sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" -e "s/@BUILD@/$(date +%Y%m%d%H%M)/" \
    -e "s|<string>XROS</string>|<string>$PLATFORM</string>|" "$R/tools/visionos/Info.plist" > "$APP/Info.plist"
# App icon: the three-layer visionOS icon (tools/visionos/icon, drawn by make_icon.swift).
if [ "$SIM" = 1 ]; then ACT_PLATFORM=xrsimulator; else ACT_PLATFORM=xros; fi
xcrun actool "$R/tools/visionos/icon/Assets.xcassets" --compile "$APP" --platform "$ACT_PLATFORM" \
  --minimum-deployment-target 2.0 --app-icon AppIcon --output-partial-info-plist "$APP/icon.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon string AppIcon" "$APP/Info.plist" >/dev/null
rm -f "$APP/icon.plist"
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
[ -f "$R/tools/visionos/args.txt" ] && cp "$R/tools/visionos/args.txt" "$APP/args.txt"
# GTAV_BRIDGE=1: stream the game data from this Mac (docs/BRIDGE.md; run `cd tools/bridge && go run .`).
# The .local name follows the Mac across networks; GTAV_BRIDGE_URL overrides it.
if [ "${GTAV_BRIDGE:-0}" = 1 ] || [ -n "${GTAV_BRIDGE_URL:-}" ]; then
  url="${GTAV_BRIDGE_URL:-http://$(scutil --get LocalHostName).local:7360}"
  printf -- '--bridge_url=%s\n' "$url" >> "$APP/args.txt"
  [ "${GTAV_BRIDGE_PREFETCH:-0}" = 1 ] && printf -- '--bridge_prefetch=true\n' >> "$APP/args.txt"
  echo "bridge: $url"
fi
if [ -n "${GTAV_SPIRV:-}" ]; then mkdir -p "$APP/spirv" && cp -R "$GTAV_SPIRV/." "$APP/spirv/"; fi

if [ "$SIM" = 1 ]; then
  for d in "$APP"/*.dylib; do codesign --force --sign - --timestamp=none "$d"; done
  codesign --force --sign - --timestamp=none "$APP"
  echo "app (simulator): $APP ($(du -sh "$APP" | cut -f1))"
  exit 0
fi

: "${TEAM_ID:?set TEAM_ID (your Apple Development team) or put it in tools/visionos/local.env}"
PROFILE=""
for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
  appid=$(security cms -D -i "$p" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null) || continue
  [ "$appid" = "$TEAM_ID.$BUNDLE_ID" ] && PROFILE="$p"
done
[ -n "$PROFILE" ] || { echo "no provisioning profile for $TEAM_ID.$BUNDLE_ID: run tools/visionos/mint_profile.sh"; exit 1; }
cp "$PROFILE" "$APP/embedded.mobileprovision"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
security cms -D -i "$PROFILE" > "$W/profile.plist" 2>/dev/null
plutil -extract Entitlements xml1 -o "$W/ent.plist" "$W/profile.plist"
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
for d in "$APP"/*.dylib; do codesign --force --sign "$IDENTITY" --timestamp=none "$d"; done
codesign --force --sign "$IDENTITY" --entitlements "$W/ent.plist" --timestamp=none --generate-entitlement-der "$APP"
codesign --verify --verbose "$APP"
echo "app: $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  DEVICE="${GTAV_XROS_DEVICE:?set GTAV_XROS_DEVICE (xcrun devicectl list devices)}"
  xcrun devicectl device install app --device "$DEVICE" "$APP"
fi
