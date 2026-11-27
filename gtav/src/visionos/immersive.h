// gtav - visionOS immersive space (docs/VISIONOS_PLAN.md, phase 2). C interface shared by the
// SwiftUI shell (App.swift, as its bridging header), the compositor loop (immersive.mm) and the
// native renderer.
#pragma once

#include <stdbool.h>

#if defined(__OBJC__) || defined(__swift__)
#include <CompositorServices/CompositorServices.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// The SDK's app (windowed_app_main_sdl.cpp, REX_IOS_EXTERNAL_MAIN): runs the game's main loop on
// the main thread and returns when the game quits.
int rex_ios_run_app(int argc, char* argv[]);

#if defined(__OBJC__) || defined(__swift__)
// The compositor loop: draws the game on a screen in the room every display frame until the space
// closes. Runs on its own thread.
void gtav_immersive_run(cp_layer_renderer_t layer);
#endif

// True while the compositor loop runs (the native renderer then renders for it, not a window).
bool gtav_immersive_active(void);

// Native renderer: the newest finished game frame, an id<MTLTexture> (BGRA8, gamma-encoded) the
// GPU is done writing. The loop keeps it until the next one; null clears it.
void gtav_immersive_publish(void* mtl_texture);

#ifdef __cplusplus
}
#endif
