#pragma once
// gtav - VR phase 3 research: find the guest function that writes the render viewport's camera
// matrix (docs/VR_CAMERA.md). macOS arm64 only; a no-op elsewhere.

namespace gtav::native::camera_watch {

// Called once when the first load has finished. With --gtav_vr_watch_camera=N it waits N
// seconds, finds the viewport(s) in guest physical memory, write-protects them for
// --gtav_vr_watch_seconds and logs the host code that wrote them.
void OnFirstLoad();

}  // namespace gtav::native::camera_watch
