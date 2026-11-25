#!/bin/sh
# Development build of gtav_fast on macOS (Apple silicon), release layout: no game code in the exe,
# it loads the gtav_game.dylib the installer built from your discs. Run dev_play_mac.sh afterwards.
# Needs: Xcode, CMake, Ninja, Python 3; rexglue-sdk/ (v0.10.0 + rexglue-sdk-gtav-linux.patch,
# built and installed with the mac-arm64 preset), thirdparty/XenosRecomp (+ xenosrecomp-gtav.patch,
# built into build/xenosrecomp-mac) and thirdparty/plume (+ plume-gtav.patch).
# JOBS=n sets the parallel jobs (default 8).
set -eu
R=$(cd "$(dirname "$0")" && pwd)
SDK=$R/rexglue-sdk/out/install/mac-arm64
B=$R/build/dev-mac
XR=$R/build/xenosrecomp-mac/XenosRecomp/XenosRecomp
[ -f "$SDK/lib/cmake/rexglue/rexglueConfig.cmake" ] || { echo "SDK not installed in $SDK"; exit 1; }
[ -x "$XR" ] || { echo "XenosRecomp not built: $XR"; exit 1; }
if [ ! -f "$B/build.ninja" ]; then
  cmake -S "$R/gtav" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_CXX_FLAGS=-mcpu=apple-m1 \
    -DCMAKE_PREFIX_PATH="$SDK" -Drexglue_DIR="$SDK/lib/cmake/rexglue" -DSDL3_DIR="$SDK/lib/cmake/SDL3" \
    -DGTAV_GAME_DLL=ON -DGTAV_XR_BIN="$XR"
fi
cmake --build "$B" -j "${JOBS:-8}"
echo "Built $B/gtav_fast"
