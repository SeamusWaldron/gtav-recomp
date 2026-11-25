#!/bin/sh
# Run the development build (dev_build_mac.sh) against an installed game folder on macOS.
# Copies gtav_fast and the SDK runtime libraries into the game folder (next to the gtav_game.dylib
# the installer built), then starts it with the launcher's flags (loader/src/install.cpp LaunchGame).
# Opening GTAV.app afterwards puts its own release runtime back (SyncRuntime), so the app always
# plays the stock build and this script always plays yours.
# Usage: dev_play_mac.sh [extra runtime flags...]
#   GTAV_HOME  game folder (default: the GTAV.app setting, else ~/Library/Application Support/GTAV Recomp)
#   GTAV_NATIVE_SHOT_DIR=<dir> GTAV_SHOT_SECS=n  periodic frame captures (PPM, 2.7 MB each)
# Output goes to the terminal and to <home>/data/logs/gtav.log; Ctrl+C or close the window to stop.
set -eu
R=$(cd "$(dirname "$0")" && pwd)
B=$R/build/dev-mac
SDK=$R/rexglue-sdk/out/install/mac-arm64
if [ -z "${GTAV_HOME:-}" ]; then
  GTAV_HOME=$(defaults read io.github.gtav-recomp GameFolder 2>/dev/null ||
              echo "$HOME/Library/Application Support/GTAV Recomp")
fi
H=$GTAV_HOME
D=$H/data
[ -f "$H/gtav_game.dylib" ] || { echo "No gtav_game.dylib in $H: install the game with GTAV.app first"; exit 1; }
[ -x "$B/gtav_fast" ] || { echo "No build: run dev_build_mac.sh first"; exit 1; }
if pgrep -x gtav_fast >/dev/null; then echo "The game is already running; quit it first"; exit 1; fi

# cp -p keeps the build's timestamps, so GTAV.app sees a different file and restores its own.
cp -p "$B/gtav_fast" "$H/gtav_fast"
for lib in librexruntime.dylib librexgpu-xenos.dylib libTracyClient.dylib; do
  cp -p "$SDK/lib/$lib" "$H/$lib"
done
mkdir -p "$H/vulkan/lib"
cp -p "$SDK/lib/libMoltenVK.dylib" "$SDK/lib/libvulkan.1.dylib" "$H/vulkan/lib/"
if [ -d "$B/tools" ]; then mkdir -p "$H/tools" && cp -Rp "$B/tools/." "$H/tools/"; fi

cd "$H"
exec ./gtav_fast \
  --game_data_root="$D/game" --user_data_root="$D/user" --update_data_root="$D/update" \
  --log_file="$D/logs/gtav.log" --gtav_native_spirv_dir="$D/spirv" \
  --gpu_plugin=xenos --headless=true --log_level=info --log_max_file_size_mb=256 --log_max_files=2 \
  --fullscreen=false --mnk_mode=true --mnk_mouse=true \
  --gtav_native=on --gtav_fps_limit=0 --gpu_skip_rendering=true --gpu_skip_rendering_lag_ms=4 \
  --vsync=false --gtav_native_vsync=false "$@"
