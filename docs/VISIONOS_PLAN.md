# Apple Vision Pro port: plan (started 2026-11-24)

Goal (owner): a native visionOS app in a **full immersive space**, the game camera driven by the
player's head (true VR, "level D"), with a controller. No iPhone-compatibility-mode detour.

Read with `docs/IOS_PORT.md`: visionOS reuses almost all of the iOS work (no JIT, guest memory
without MAP_JIT, read-only bundle, no child processes, MoltenVK inside the app, game library and
shaders built on the Mac). `TARGET_OS_IPHONE` is 1 on visionOS, so the iOS code paths in the SDK,
gtav and plume apply; CMake checks for `CMAKE_SYSTEM_NAME STREQUAL "iOS"` need a visionOS case.

## Architecture

- **App shell**: SwiftUI `App` with an `ImmersiveSpace` (full immersion) hosting a
  `CompositorLayer` (Compositor Services). The layer's render loop runs on our own thread and
  hands us, every display frame (90-100 Hz): per-eye Metal colour/depth textures, the predicted
  device anchor (head pose), and per-eye view transforms + projections.
- **Runtime**: the existing SDK + gtav_fast, started from the shell on its own threads, as on iOS.
  SDL3 stays for gamepads and audio; its video window is not shown in the immersive space.
- **Rendering**: Plume (Vulkan) on MoltenVK renders the game into Vulkan images; those images are
  Metal textures underneath (VK_EXT_metal_objects / vkGetMTLTextureMVK), blitted or sampled into
  the compositor's drawables. One Metal command queue shared, or MTLSharedEvent for sync.
- **Head tracking into the game**: the head pose (relative to a recentre pose) replaces the
  orientation (later position) of GTA's final camera frame, via a hook on the function that
  publishes the frame the renderer and culling use. Found by our own analysis of our own copy
  (manifest hooks, the d3d_map / shader-constant view matrices); never the leaked source.
- **Stereo**: per-eye rendering of the 3D world passes (G-buffer, lighting, transparent) with
  per-eye view/projection constants patched at replay time in backend.cpp; screen-space post and
  the HUD shared. Interim: mono render + compositor reprojection with depth.
- **Frame rate**: the compositor wants 90+ Hz; the game renders 30-60. The compositor's own
  reprojection (we submit depth) covers the gap at first; later an explicit reprojection pass
  re-presenting the newest game frame at the latest head pose every display frame.
- **HUD/menus**: a flat panel in the immersive space, from the pre-HUD / HUD split of the frame.
- **Game data**: Wi-Fi install from the Mac's checked game folder (data/, verified with
  expected.txt); for development, `xcrun devicectl device copy to` into the app container.

## Phases

| # | Deliverable | Proves |
|---|---|---|
| 0 | Toolchain: visionOS SDK, CMake >= 3.28, signing, device in Developer Mode | can deploy |
| 1 | SDK runtime + MoltenVK + gtav_fast built for visionOS; game library compiled for xros on the Mac; shaders from the Mac's cache; app boots to the game in a **flat window** | CPU/runtime/renderer on the device |
| 2 | Immersive space + Compositor Services; the mono game frame on a large world-locked screen | Vulkan-to-compositor plumbing, timing |
| 3 | Head rotation drives the game camera (hook); mono frame shown to both eyes at the compositor's pose, with depth | VR camera |
| 4 | True stereo: per-eye world passes | depth / scale |
| 5 | HUD panel, recentre, comfort (vehicle camera, cutscenes as a screen), 90 Hz reprojection, Wi-Fi install, controls | playable |

## Status

- Phase 0: Xcode 27.2 + visionOS 27.2 SDK present, Apple Development identity present, the
  Vision Pro is known to Xcode (needs Developer Mode, awake, same network for deploys). CMake
  upgraded to 4.5.1 (visionOS needs >= 3.28; CMake 4 may need -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  for old third-party CMake files).
- Phase 1 (2026-11-24), built and signed, **not yet run on the device**:
  - SDK: `cmake -S rexglue-sdk -B rexglue-sdk/out/build/xros-arm64 -G Ninja -DCMAKE_SYSTEM_NAME=visionOS
    -DCMAKE_OSX_SYSROOT=xros -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 -DCMAKE_C/CXX_FLAGS=-mcpu=apple-m2
    -DCMAKE_CXX_STANDARD=23 -DREXGLUE_ENABLE_TRACY=OFF -DREXGLUE_BUILD_TESTS=OFF
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX=.../out/install/xros-arm64`, ninja,
    install; then delete its ~/.cmake/packages/rexglue entry. MoltenVK is built from source for
    visionOS (thirdparty/CMakeLists.txt; moltenvk/Common links UIKit + CoreGraphics there), output
    in rexglue-sdk/out/ios-arm64 (REX_PLATFORM is still "ios-arm64" for visionOS).
  - Shell: `cmake -S gtav -B build/xros-shell` with the same platform flags, -DGTAV_GAME_DLL=ON,
    CMAKE_PREFIX_PATH/CMAKE_FIND_ROOT_PATH = the xros SDK install. gen_interface.py builds the stub
    game library for the platform's SDK (GTAV_STUB_SDK = xros / iphoneos / macosx).
  - Code: CMake's iOS checks also match visionOS (GTAV_IOS + GTAV_VISIONOS); plume reads the window
    scale from its traits (no UIScreen on visionOS); backend.cpp: visionOS is not GTAV_MOBILE
    (desktop SPIR-V, the Mac's data/spirv as is; render scale 1.0) but is GTAV_JETSAM (cache
    budgets, low-memory shrink); textures.cpp: BC formats on the GPU (M2), not CPU-decoded.
  - Game library: codegen with the release app's rexglue + manifest into
    `<game folder>/data/build-xros` (game-derived: never in the repo), then
    `tools/game_dll/build_game_dll.py <Xcode toolchain bin> <generated> build/xros-shell/game_interface
    <out> --visionos --runtime rexglue-sdk/out/install/xros-arm64/lib/librexruntime.dylib`.
  - Signing: tools/visionos/mint_profile.sh minted the dev App ID (`org.gtavrecomp.vision.<team>`, team and device in the git-ignored
    tools/visionos/local.env) with increased-memory-limit + extended-virtual-addressing, the Vision Pro included.
  - App: tools/visionos/make_app.sh (Info.plist + args.txt from tools/visionos) ->
    `<game folder>/data/build-xros/GTAV.app` (signed). Next: `make_app.sh --install`, then
    tools/visionos/push_data.sh (game, update, user: ~15 GB over Wi-Fi), launch, read
    Documents/logs/gtav.log. Things to check first: MoltenVK reports BC support; the guest memory
    mapping succeeds (extended VA); SDL's window appears in the Shared Space.
- Simulator (2026-11-24): simulator builds of the SDK (out/install/xrsim-arm64, REX_PLATFORM
  xrsim-arm64), shell (build/xrsim-shell) and game library (`--visionos --simulator`);
  `tools/visionos/run_sim.sh` (data symlinked from the Mac install, no copy; this Xcode has no
  Simulator.app, the device runs headless). Result: SDL uikit window, MoltenVK, guest memory
  arena (0x70_0000_0000 / 0x71_0000_0000), XEX load and the TU27 patch all work; then a Metal
  assertion kills it in the emulated GPU's VulkanCommandProcessor::SetupContext:
  `Linear texture can only be created on buffers with MTLStorageModePrivate in the simulator`
  (MoltenVK MVKBufferView::getMTLTexture, a texel buffer view). The simulator GPU is "Apple
  family 2" with no BC formats: not representative of the device (Apple 8/9), so rendering is
  tested on the device only. `--gpu_plugin=` (empty) is a CLI parse error, not "no GPU".
