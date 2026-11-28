#pragma once
// gtav - VR phase 3: the player's head turns the game's own camera (docs/VR_CAMERA.md).

namespace gtav::vr {

// The head's rotation relative to the recentre pose, in the camera's own frame: columns are the
// new right, up and back axes, each as (right, up, back) components of the old ones (the game
// camera's rows are right, up, back, position; it looks along -back, like ARKit's -z).
// Column-major, 9 floats. Identity (or never called) leaves the camera alone.
void SetHeadRotation(const float rotation[9]);

}  // namespace gtav::vr
