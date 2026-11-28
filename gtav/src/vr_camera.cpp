// gtav - VR phase 3: the player's head turns the game's own camera (see vr_camera.h).
//
// The game keeps its viewports in a list at 0x839FF470 + 2144 (count at + 2148); each holds a
// 944-byte grcViewport at + 16 (camera matrix at + 192: rows right, up, back, position,
// big-endian floats, world Z up; view matrix, its inverse, at + 256). Every render phase takes
// its own copy of a game viewport with sub_832B84C8, through its vtable (sub_826C8000,
// sub_826C5BD8...). Turning those copies turns the picture; the game viewports themselves, and
// so the camera system and the game's logic, are left alone and nothing accumulates. The
// position stays.
//
// The per-frame view update sub_825A2860 also copies the largest game viewport into
// 0x839FF470 + 2192 (sub_8231E430) and sets the main viewport and the CPU culling frustum from
// it; that copy is turned too and put back when the update returns. Turning only that one turned
// the culling but not the picture (docs/VR_CAMERA.md).

#include "vr_camera.h"

#include <rex/cvar.h>
#include <rex/hook.h>
#include <rex/logging.h>
#include <rex/system/xmemory.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>

REXCVAR_DEFINE_DOUBLE(gtav_vr_test_yaw, 0.0, "GTAV",
                      "VR test: turn the game camera this many degrees to the right (0: off)");
REXCVAR_DEFINE_BOOL(gtav_vr_test_sweep, false, "GTAV",
                    "VR test: swing the game camera 30 degrees left and right every 5 s");
REXCVAR_DEFINE_BOOL(gtav_vr_restore, true, "GTAV",
                    "VR research: put the camera back when the frame update returns");
REXCVAR_DEFINE_BOOL(gtav_vr_head_aims, true, "GTAV",
                    "VR: turn the camera frame itself, so the game aims where the head looks (off: "
                    "only the picture turns, see gtav_vr_turn_copies)");
REXCVAR_DEFINE_BOOL(gtav_vr_turn_copies, true, "GTAV",
                    "VR: turn every copy taken of a game viewport (the render phases take "
                    "theirs with sub_832B84C8)");
REXCVAR_DEFINE_BOOL(gtav_vr_log, false, "GTAV",
                    "VR: log once a second how the camera was turned");

namespace gtav::vr {

constexpr uint32_t kCameraObject = 0x839FF470;
constexpr uint32_t kCameraMatrix = kCameraObject + 2384;  // 0x839FFDC0

std::mutex g_head_mutex;
float g_head[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
std::atomic<bool> g_head_set{false};

uint32_t LoadBE(const uint8_t* p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
float FloatBE(const uint8_t* p) {
  uint32_t u = LoadBE(p);
  float f;
  std::memcpy(&f, &u, 4);
  return f;
}
void StoreFloatBE(uint8_t* p, float f) {
  uint32_t u;
  std::memcpy(&u, &f, 4);
  p[0] = uint8_t(u >> 24), p[1] = uint8_t(u >> 16), p[2] = uint8_t(u >> 8), p[3] = uint8_t(u);
}

// The rotation to apply now (column-major, camera frame); false when there is none.
bool CurrentRotation(float out[9]) {
  if (g_head_set.load(std::memory_order_acquire)) {
    std::lock_guard<std::mutex> lock(g_head_mutex);
    std::memcpy(out, g_head, sizeof(g_head));
    return true;
  }
  double yaw = REXCVAR_GET(gtav_vr_test_yaw);
  if (REXCVAR_GET(gtav_vr_test_sweep)) {
    using namespace std::chrono;
    static const auto start = steady_clock::now();
    double t = duration<double>(steady_clock::now() - start).count();
    yaw += 30.0 * std::sin(t * 2 * M_PI / 5.0);
  }
  if (yaw == 0) return false;
  // Turning right by yaw: right' = cos R + sin B, back' = cos B - sin R, up stays.
  float c = float(std::cos(yaw * M_PI / 180)), s = float(std::sin(yaw * M_PI / 180));
  const float r[9] = {c, 0, s, 0, 1, 0, -s, 0, c};
  std::memcpy(out, r, sizeof(r));
  return true;
}

void Log(const uint8_t* before, const uint8_t* after) {
  static std::atomic<uint32_t> frames{0};
  static std::atomic<int64_t> last{0};
  frames.fetch_add(1);
  int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
                    std::chrono::steady_clock::now().time_since_epoch())
                    .count();
  if (int64_t prev = last.load(); now != prev && last.compare_exchange_strong(prev, now))
    REXLOG_INFO("[vr] {} frames turned; back ({:.3f} {:.3f} {:.3f}) -> ({:.3f} {:.3f} {:.3f})",
                frames.exchange(0), FloatBE(before + 32), FloatBE(before + 36),
                FloatBE(before + 40), FloatBE(after + 32), FloatBE(after + 36), FloatBE(after + 40));
}

void SetHeadRotation(const float rotation[9]) {
  std::lock_guard<std::mutex> lock(g_head_mutex);
  std::memcpy(g_head, rotation, sizeof(g_head));
  g_head_set.store(true, std::memory_order_release);
}

}  // namespace gtav::vr

namespace {
thread_local bool g_in_view_update = false;
thread_local bool g_turned = false;
thread_local uint8_t g_saved[128];

// Turns the camera matrix at m (rows right, up, back, position) by rot, and when view is set,
// rewrites the view matrix there as its inverse (3x3 transposed, translation -P.axis).
void Turn(uint8_t* m, const float rot[9], uint8_t* view) {
  using namespace gtav::vr;
  float axes[3][3], pos[3], out[3][3];
  for (int a = 0; a < 3; ++a)
    for (int i = 0; i < 3; ++i) axes[a][i] = FloatBE(m + 16 * a + 4 * i);
  for (int i = 0; i < 3; ++i) pos[i] = FloatBE(m + 48 + 4 * i);
  for (int col = 0; col < 3; ++col)
    for (int i = 0; i < 3; ++i) {
      out[col][i] = rot[3 * col + 0] * axes[0][i] + rot[3 * col + 1] * axes[1][i] +
                    rot[3 * col + 2] * axes[2][i];
      StoreFloatBE(m + 16 * col + 4 * i, out[col][i]);
    }
  if (!view) return;
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) StoreFloatBE(view + 16 * i + 4 * j, out[j][i]);
  for (int j = 0; j < 3; ++j)
    StoreFloatBE(view + 48 + 4 * j,
                 -(pos[0] * out[j][0] + pos[1] * out[j][1] + pos[2] * out[j][2]));
}
}  // namespace

// The frame update: the camera is turned only inside it, and put back when it returns.
REX_EXTERN(__imp__sub_825A2860);
REX_HOOK_RAW(sub_825A2860) {
  g_in_view_update = true;
  g_turned = false;
  __imp__sub_825A2860(ctx, base);
  g_in_view_update = false;
  if (g_turned && REXCVAR_GET(gtav_vr_restore))
    std::memcpy(rex::memory::GuestPtr(base, gtav::vr::kCameraMatrix), g_saved, 128);
}

// Picks the active camera and copies its frame into 0x839FF470 + 2192 (the matrix lands at
// +2384), first thing in the frame update. Turned right after that copy.
REX_EXTERN(__imp__sub_8231E430);
REX_HOOK_RAW(sub_8231E430) {
  using namespace gtav::vr;
  const uint32_t self = ctx.r3.u32;
  __imp__sub_8231E430(ctx, base);
  float rot[9];
  if (REXCVAR_GET(gtav_vr_head_aims) || !g_in_view_update || self != kCameraObject ||
      !CurrentRotation(rot))
    return;
  uint8_t* m = rex::memory::GuestPtr(base, kCameraMatrix);
  std::memcpy(g_saved, m, 128);
  g_turned = true;
  if (REXCVAR_GET(gtav_vr_log)) {
    // Check the view matrix convention: the game's own view at +64 against the inverse Turn
    // would write for the unturned camera.
    static std::atomic<int64_t> last{0};
    int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
                      std::chrono::steady_clock::now().time_since_epoch()).count();
    if (int64_t prev = last.load(); now != prev && last.compare_exchange_strong(prev, now)) {
      uint8_t probe[128];
      std::memcpy(probe, g_saved, 128);
      const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
      Turn(probe, identity, probe + 64);
      float worst = 0;
      for (int o = 64; o < 128; o += 4)
        worst = std::max(worst, std::fabs(FloatBE(probe + o) - FloatBE(g_saved + o)));
      REXLOG_INFO("[vr] view matrix vs inverse of camera: max diff {:.4f}; view row3 ({:.2f} {:.2f} {:.2f} {:.2f})",
                  worst, FloatBE(g_saved + 112), FloatBE(g_saved + 116), FloatBE(g_saved + 120),
                  FloatBE(g_saved + 124));
    }
  }
  Turn(m, rot, m + 64);
  if (REXCVAR_GET(gtav_vr_log)) Log(g_saved, m);
}

namespace {
// Whether guest address grc is the grcViewport (+16) of one of the game viewports.
bool IsGameViewport(uint8_t* base, uint32_t grc) {
  using namespace gtav::vr;
  const uint8_t* mgr = rex::memory::GuestPtr(base, kCameraObject);
  uint32_t list = LoadBE(mgr + 2144);
  uint32_t count = uint32_t(mgr[2148]) << 8 | mgr[2149];
  for (uint32_t i = 0; i < count && i < 16; ++i)
    if (LoadBE(rex::memory::GuestPtr(base, list + 4 * i)) + 16 == grc) return true;
  return false;
}
}  // namespace

// Copies a 944-byte grcViewport (r3 = destination, r4 = source). The render phases take their
// viewport from the game viewport with it (sub_826C8000 and the like, through their vtables).
REX_EXTERN(__imp__sub_832B84C8);
REX_HOOK_RAW(sub_832B84C8) {
  using namespace gtav::vr;
  const uint32_t dst = ctx.r3.u32, src = ctx.r4.u32;
  __imp__sub_832B84C8(ctx, base);
  if (REXCVAR_GET(gtav_vr_head_aims) || !REXCVAR_GET(gtav_vr_turn_copies) ||
      dst == kCameraObject + 2192)
    return;
  float rot[9];
  if (!IsGameViewport(base, src) || !CurrentRotation(rot)) return;
  uint8_t* m = rex::memory::GuestPtr(base, dst + 192);
  Turn(m, rot, m + 64);
  if (REXCVAR_GET(gtav_vr_log)) {
    static std::atomic<uint32_t> copies{0};
    static std::atomic<int64_t> last{0};
    copies.fetch_add(1);
    int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
                      std::chrono::steady_clock::now().time_since_epoch()).count();
    if (int64_t prev = last.load(); now != prev && last.compare_exchange_strong(prev, now))
      REXLOG_INFO("[vr] {} game viewport copies turned (last into 0x{:08X})", copies.exchange(0), dst);
  }
}

// The camera update (sub_82376EB8) builds the frame of the active camera on its stack (matrix
// rows right, forward, up at +16, +32, +48, position at +64: not the viewport's right, up,
// back), then hands it to sub_8236E880
// (r4 = frame, r6 = game viewport), which sets the game viewport from it; afterwards the frame is
// saved for the game logic (aiming reads it). Turned on the way in, everything downstream sees the
// head: the viewport, the render copies, the culling and the aim.
REX_EXTERN(__imp__sub_8236E880);
REX_HOOK_RAW(sub_8236E880) {
  using namespace gtav::vr;
  float rot[9];
  if (REXCVAR_GET(gtav_vr_head_aims) && CurrentRotation(rot)) {
    uint8_t* frame = rex::memory::GuestPtr(base, ctx.r4.u32);
    // As right, up, back rows (the order Turn and the head rotation use), and back again.
    uint8_t m[64], before[64];
    std::memcpy(m, frame + 16, 16);
    std::memcpy(m + 16, frame + 48, 16);
    for (int i = 0; i < 3; ++i) StoreFloatBE(m + 32 + 4 * i, -FloatBE(frame + 32 + 4 * i));
    std::memcpy(m + 48, frame + 64, 16);
    std::memcpy(before, m, 64);
    Turn(m, rot, nullptr);
    std::memcpy(frame + 16, m, 12);
    std::memcpy(frame + 48, m + 16, 12);
    for (int i = 0; i < 3; ++i) StoreFloatBE(frame + 32 + 4 * i, -FloatBE(m + 32 + 4 * i));
    if (REXCVAR_GET(gtav_vr_log)) Log(before, m);
  }
  __imp__sub_8236E880(ctx, base);
}
