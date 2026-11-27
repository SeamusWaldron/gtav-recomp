# VR camera: where the game's camera is, and how head rotation gets in (phase 3, started 2026-11-26)

Goal (docs/VISIONOS_PLAN.md, phase 3): the player's head rotation turns the game camera, so the
game culls and renders what the player looks at. Rotating the picture afterwards would leave holes
at the edges, because the game culls on the CPU against its own frustum. So the rotation has to go
in where the game sets up its camera, through a hook on our own recompiled code. Everything here
comes from analysis of our own build, at run time, and from dumps of its memory. Nothing comes from
leaked source.

## Method

1. A frame dump (`--gtav_native_dump_after_load=600`, which dumps 600 guest frames after the first
   load ends) holds each draw's 2048 constant floats (`draws.bin`).
   `tools/native/vr/find_view.py draws.bin` lists the constant registers that hold an orthonormal
   3x3 block, grouped by value.
2. `--gtav_native_dump_memory=true` also saves the guest's 512 MB of physical memory with that
   dump (`physical.bin`). `tools/native/vr/find_camera_memory.py DUMP_DIR` finds every copy of the
   camera matrix in it.
3. Next: a write watch on macOS. Write-protect the host page behind the viewport, record the
   faulting store's address and map it to its `sub_<guest address>` function. `gtav_game.dylib`
   keeps its 96k local function symbols. `gtav/src/native/write_watch.cpp` is Linux-only
   (userfaultfd).

## Findings (Mac dev build, story-mode spawn, 2026-11-26)

- **The camera's world matrix is vertex constants c12..c15** of the world draws. The rows are
  right, up, forward and position; the world is Z up. In one frame: right (0.854, 0.520, 0), up
  (0.002, -0.004, 1.000), forward (0.520, -0.854, -0.004), position (5314.0, -5214.3, 83.6). vs c0
  is the object's world matrix (its position is a few metres from the camera).
- In memory the matrix has about 2900 copies. Most are in `0x079xxxxx..0x07Fxxxxx`, which looks
  like the command buffer's constant uploads (one per draw that sets it). The copies outside that
  band:
  - `phys 0x0c048fa0`: preceded by `1280 720` and followed by `0.5 1497.2 0.647 0.364`. That reads
    as a render viewport: the screen size, the camera matrix, near and far planes, and the tangents
    of the half field of view (0.647 / 0.364 = 16:9; 2 atan 0.364 = 40 degrees vertical).
  - `0x0c3c55c0`, `0x0c3ff580`, `0x0c71abf0`, `0x0cd9f580` and others: the camera matrix
    followed by its transpose (the view rotation), with slightly different values (0.857 against
    0.855). These are per-frame copies from other moments, so the game thread is ahead of the render
    thread.
- To do: find which function writes the viewport's camera matrix, and with which guest virtual
  address. The watch has to be on the virtual view the game writes through, not the physical
  one.

## Plan for the hook

Hook the function that sets the viewport's camera matrix (or the one that publishes the final
camera frame). Multiply its rotation by the head rotation relative to a recentre pose; the
compositor already has the pose from ARKit (`gtav/src/visionos/immersive.mm`). Keep the game's
position at first: rotation only, so phase 3 cannot move the player. On the screen in the room the
picture then turns with the head. Once that works, the phase 3 display shows the frame head-locked,
at the pose it was rendered for, instead of on a fixed screen.
