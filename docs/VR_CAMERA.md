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
3. `--gtav_vr_watch_camera=N` (macOS arm64, `gtav/src/native/camera_watch.cpp`): N seconds
   after the first load it finds the viewport in physical memory by its shape (it is heap
   allocated: `0x0c048fa0`, `0x0C046B48` and `0x0C04B048` in three runs), write-protects the host
   pages behind it in the 0xA/0xC/0xE views for `--gtav_vr_watch_seconds`, and logs every store
   on them with its pc, lr and caller. `dladdr` names the `sub_<guest address>` directly, because
   `gtav_game.dylib` keeps its local symbols. The watch sits in front of the SDK's SIGBUS handler:
   the SDK's stale-protection recovery would otherwise unprotect the page silently.

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
- **The writer is `sub_83103968(r3 = viewport - 8, r4, r5 = camera matrix)`**, called
  every frame (from `sub_83107940`), through the 0xC0000000 view. It sets a flag byte at
  r3+112 first, and then copies the 64-byte matrix from r5 to r3+16 and derives the view and
  the frustum from it (r3+128 on). The watch saw only that byte (60 a second): after the first
  fault the page stays writable until the watch re-protects it, so the matrix stores in the
  same call go unseen. With the player standing still, the viewport's values did not change
  over 5 s.

## Where the render camera comes from

- `sub_825A2860` is the per-frame view update. It starts with `sub_8231E430(0x839FF470)`,
  which picks the active camera and copies its frame into `0x839FF470 + 2192`; the camera's
  world matrix lands at `+2384` (`0x839FFDC0`). It then sets the main viewport from that
  matrix (`sub_83107940`: `sub_83103968` copies it into the viewport and derives the frustum,
  and a second copy goes to the viewport's `+336`), and updates the render phases
  (`sub_8259F0F0`, `sub_825997B0`, `sub_8259F688`, `sub_8310FFD0`...), which read the camera
  object directly.
- Hooking `sub_83103968` alone (rotate its matrix argument, restore after) turned the viewport
  (checked in a memory dump) but not the picture: the GPU's vs c12..c15 stayed unrotated, and so
  did every per-phase copy (matrix followed by its transpose) in the draw-list memory.
- Page-protection watches miss stores on busy pages: after the first fault on a 16 KB page the
  page stays writable until it is re-protected, so "0 writes" in a block is not proof. The
  camera object's page takes about 600 unrelated faults a second.

## The hook (`gtav/src/vr_camera.cpp`)

`sub_825A2860` marks the frame update on its thread and, when it returns, puts the matrix back.
`sub_8231E430`, when called on `0x839FF470` inside that update, turns the matrix it just copied
(right, up and forward; the position stays). The viewport, the CPU frustum and every render
phase see the turned camera; the camera system and the game's logic never do, and nothing
accumulates. Tests on the Mac: `--gtav_vr_test_yaw=30` (degrees right),
`--gtav_vr_test_sweep=true` (30 degrees either way every 5 s), `--gtav_vr_log=true`. The headset
calls `gtav::vr::SetHeadRotation()` (`vr_camera.h`). Adding or removing a hook means rebuilding
`gtav_game.dylib` (its hook list is built into it): `build_game_dll.py` with the dev build's
`game_interface`. `--gtav_vr_turn_copies` (on by default) turns the render phases' copies (below).

### Status (2026-11-26): culling turns, the picture does not

With only the two hooks above and `--gtav_vr_test_yaw=180`, the camera object's matrix flipped
every frame and the CPU culling followed it (whole rooms went black), but the GPU's view did not
turn, with or without `--gtav_vr_restore=false`.

### Status (2026-11-27): the picture turns on the Mac

`sub_8231E430` picks the largest of the game viewports (a pointer list at `0x839FF470 + 2144`,
count at `+ 2148`; each viewport holds a 944-byte grcViewport at `+16`, constructed by
`sub_832AD258` with six identity matrices: camera matrix at `+192`, view matrix, its inverse, at
`+256`) and copies it with `sub_832B84C8` (the grcViewport copy) into `0x839FF470 + 2192`. The
render phases do not read that copy: each phase copies its own viewport from the game viewport it
points at (`phase + 996`) into `phase + 32`, with the same `sub_832B84C8`, from its vtable
(`sub_826C8000`, `sub_826C5BD8`, `sub_826C5C00`...). Turning the game viewports themselves inside
the frame update and putting them back did not turn the picture either: the phases copy later.

The hook on `sub_832B84C8` turns every copy whose source is a game viewport: the camera matrix
(right, up, forward; the position stays) and the view matrix rewritten as its inverse (checked at
run time: the game's own view matrix matches that inverse to 0.0005). About 13 copies a frame.
With `--gtav_vr_test_sweep=true` the picture pans 30 degrees either way with the player standing
still, cleanly. At 180 degrees the picture is heavily blurred and over-exposed: motion blur (and
probably auto-exposure) compare against an unturned previous frame. Not yet checked: whether a
game-logic copy is among those turned (aiming, the HUD's world-to-screen), and whether shadows
and reflections follow correctly.

## Plan for the hook

Hook the function that sets the viewport's camera matrix (or the one that publishes the final
camera frame). Multiply its rotation by the head rotation relative to a recentre pose; the
compositor already has the pose from ARKit (`gtav/src/visionos/immersive.mm`). Keep the game's
position at first: rotation only, so phase 3 cannot move the player. On the screen in the room the
picture then turns with the head. Once that works, the phase 3 display shows the frame head-locked,
at the pose it was rendered for, instead of on a fixed screen.
