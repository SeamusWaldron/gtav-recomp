// gtav - VR phase 3 research: which guest function writes the render viewport's camera matrix
// (see camera_watch.h, docs/VR_CAMERA.md).
//
// The viewport is a block in guest physical memory: the screen size as floats, the camera's
// 4x4 world matrix (rows right, up, forward, position) and then near, far, tan(half FOV x),
// tan(half FOV y). Its address is heap-allocated, so it is found by that shape, not by a fixed
// address. The game writes it through the 0xA0000000 / 0xC0000000 / 0xE0000000 physical views;
// all three host pages behind each viewport are made read-only, and every faulting store is
// recorded with its host pc and lr (gtav_game.dylib keeps its sub_<guest address> symbols, so
// `nm` maps an offset to the guest function), the page is made writable again, and a thread
// re-protects it a moment later. The SDK's own fault handler would quietly unprotect the page
// first (its stale-protection recovery), so this one sits in front of it at the signal level
// and passes every other fault on.

#include "camera_watch.h"

#include <rex/cvar.h>
#include <rex/kernel.h>
#include <rex/logging.h>
#include <rex/system/xmemory.h>

REXCVAR_DEFINE_INT32(gtav_vr_watch_camera, 0, "GTAV",
                     "VR research (macOS): this many seconds after the first load, find the render "
                     "viewport and log the code that writes its camera matrix (0: off)");
REXCVAR_DEFINE_UINT32(gtav_vr_watch_guest, 0, "GTAV",
                      "VR research (macOS): with --gtav_vr_watch_camera, watch these 64 bytes at a "
                      "guest address instead of the viewport");
REXCVAR_DEFINE_BOOL(gtav_vr_watch_reads, false, "GTAV",
                    "VR research (macOS): the watch also catches reads (pages made inaccessible)");
REXCVAR_DEFINE_BOOL(gtav_vr_watch_copies, false, "GTAV",
                    "VR research (macOS): watch the render copies of the camera (its matrix followed "
                    "by its transpose) instead of the viewport");
REXCVAR_DEFINE_UINT32(gtav_vr_watch_from, 0, "GTAV",
                      "VR research (macOS): start the viewport / camera copy search at this physical "
                      "address");
REXCVAR_DEFINE_BOOL(gtav_vr_watch_source, false, "GTAV",
                    "VR research (macOS): watch the camera matrix of each game viewport in the "
                    "viewport list (0x839FF470 + 2144) instead");
REXCVAR_DEFINE_INT32(gtav_vr_watch_seconds, 5, "GTAV",
                     "VR research (macOS): how long --gtav_vr_watch_camera watches for writes");

#if defined(__APPLE__) && defined(__aarch64__)

#include "safe_read.h"

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace gtav::native::camera_watch {
namespace {

constexpr uint32_t kPhysicalSize = 512u << 20;
constexpr uint32_t kViewBases[] = {0xA0000000u, 0xC0000000u, 0xE0000000u};
constexpr uint32_t kViewportBytes = 88;  // w h | 4x4 matrix | near far tanX tanY
constexpr int kMaxViewports = 8;
constexpr int kMaxPages = kMaxViewports * 3 * 2;
constexpr int kMaxHits = 512;
constexpr uint32_t kBias = 0x80000000u;  // signed offsets, stored so unsigned order works

struct Range {
  uintptr_t begin, end;  // host bytes of one viewport in one view
  uint32_t phys;
  uint32_t view;
};

struct Hit {
  std::atomic<uint64_t> key{0};  // pc and lr hashed, or 0 for a free slot
  uint64_t pc = 0, lr = 0;
  uint64_t caller = 0;  // return address one frame up the fp chain
  std::atomic<uint32_t> count{0};
  std::atomic<uint32_t> lo{~0u}, hi{0};  // byte offsets from the viewport start, + kBias
  std::atomic<uint32_t> range{0};
};

Range g_ranges[kMaxViewports * 3];
int g_range_count = 0;
uintptr_t g_pages[kMaxPages];
int g_page_count = 0;
size_t g_page_size = 0;
std::atomic<bool> g_active{false};
std::atomic<bool> g_rearm{false};
std::atomic<uint32_t> g_other_faults{0};  // on a watched page, outside every viewport
std::atomic<uint32_t> g_viewport_faults{0};
std::atomic<uint32_t> g_dropped{0};
Hit g_hits[kMaxHits];
struct sigaction g_prev_bus, g_prev_segv;

uint32_t LoadBE(const uint8_t* p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
float FloatBE(const uint8_t* p) {
  uint32_t u = LoadBE(p);
  float f;
  std::memcpy(&f, &u, 4);
  return f;
}

// A viewport starts at p: the screen size, an orthonormal camera rotation, sane clip planes and
// a field of view whose aspect matches the screen.
bool IsViewport(const uint8_t* p, float out[22]) {
  for (int i = 0; i < 22; ++i) {
    out[i] = FloatBE(p + 4 * i);
    if (!std::isfinite(out[i])) return false;
  }
  float w = out[0], h = out[1];
  if (w < 256 || w > 8192 || h < 144 || h > 8192 || w != std::floor(w) || h != std::floor(h))
    return false;
  const float* m = out + 2;
  for (int r = 0; r < 3; ++r) {
    const float* a = m + 4 * r;
    if (std::fabs(a[0] * a[0] + a[1] * a[1] + a[2] * a[2] - 1) > 2e-3f) return false;
    for (int s = r + 1; s < 3; ++s) {
      const float* b = m + 4 * s;
      if (std::fabs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) > 2e-3f) return false;
    }
  }
  float near_z = out[18], far_z = out[19], tan_x = out[20], tan_y = out[21];
  return near_z > 0.01f && near_z < 10 && far_z > near_z * 10 && far_z < 1e6f && tan_x > 0.05f &&
         tan_x < 5 && tan_y > 0.05f && tan_y < 5 && std::fabs(tan_x / tan_y - w / h) < 0.05f;
}

// A render copy of the camera starts 8 bytes before p (to line up with a viewport's matrix): the
// camera matrix (orthonormal rotation, then the position with w = 1) and right after it the
// rotation's transpose (the view rotation).
bool IsCameraCopy(const uint8_t* p, float out[22]) {
  float m[28];
  for (int i = 0; i < 28; ++i) {
    m[i] = FloatBE(p + 8 + 4 * i);
    if (!std::isfinite(m[i])) return false;
  }
  if (m[15] != 1.0f || m[3] != 0 || m[7] != 0 || m[11] != 0) return false;
  for (int r = 0; r < 3; ++r) {
    const float* a = m + 4 * r;
    if (std::fabs(a[0] * a[0] + a[1] * a[1] + a[2] * a[2] - 1) > 2e-3f) return false;
    for (int c = 0; c < 3; ++c)
      if (std::fabs(m[16 + 4 * c + r] - a[c]) > 1e-4f) return false;
  }
  if (std::fabs(m[12]) + std::fabs(m[13]) < 1.0f) return false;  // a real place, not the origin
  for (int i = 0; i < 22; ++i) out[i] = i < 2 ? 0 : (i < 18 ? m[i - 2] : 0);
  return true;
}

std::vector<uint32_t> FindViewports() {
  const bool copies = REXCVAR_GET(gtav_vr_watch_copies);
  std::vector<uint32_t> found;
  constexpr uint32_t kChunk = 64 * 1024;
  std::vector<uint8_t> buf(kChunk + kViewportBytes);
  float v[22];
  for (uint32_t a = REXCVAR_GET(gtav_vr_watch_from) & ~(kChunk - 1);
       a < kPhysicalSize && int(found.size()) < kMaxViewports; a += kChunk) {
    const uint8_t* src = REX_KERNEL_MEMORY()->TranslatePhysical(a);
    uint32_t have = kChunk + kViewportBytes;
    if (a + have > kPhysicalSize || !SafeReadMemory(buf.data(), src, have)) {
      have = kChunk;
      if (!SafeReadMemory(buf.data(), src, have)) continue;
    }
    for (uint32_t o = 0; o + kViewportBytes <= have && o < kChunk; o += 4) {
      if (copies ? (a + o >= 0x07900000 && a + o < 0x08000000) || !IsCameraCopy(buf.data() + o, v)
                 : !IsViewport(buf.data() + o, v))
        continue;
      found.push_back(a + o);
      REXLOG_INFO(
          "[vr] viewport at phys 0x{:08X}: {}x{} right ({:.3f} {:.3f} {:.3f}) forward ({:.3f} "
          "{:.3f} {:.3f}) position ({:.1f} {:.1f} {:.1f}) near {:.2f} far {:.1f} tan {:.3f} {:.3f}",
          a + o, v[0], v[1], v[2], v[3], v[4], v[10], v[11], v[12], v[14], v[15], v[16], v[18], v[19],
          v[20], v[21]);
      if (int(found.size()) == kMaxViewports) break;
    }
  }
  return found;
}

void Record(uint64_t pc, uint64_t lr, uint64_t caller, uint32_t range, uint32_t offset) {
  uint64_t key = pc ^ (lr << 1);
  if (!key) key = 1;  // 0 marks a free slot
  for (uint32_t i = 0, slot = uint32_t(key * 0x9E3779B97F4A7C15ull >> 55); i < kMaxHits; ++i) {
    Hit& h = g_hits[(slot + i) % kMaxHits];
    uint64_t cur = h.key.load(std::memory_order_acquire);
    if (cur == 0 && h.key.compare_exchange_strong(cur, key, std::memory_order_acq_rel)) {
      h.pc = pc, h.lr = lr, h.caller = caller;
      h.range.store(range);
    } else if (cur != key) {
      continue;
    }
    h.count.fetch_add(1, std::memory_order_relaxed);
    for (uint32_t lo = h.lo.load(); offset < lo && !h.lo.compare_exchange_weak(lo, offset);) {
    }
    for (uint32_t hi = h.hi.load(); offset > hi && !h.hi.compare_exchange_weak(hi, offset);) {
    }
    return;
  }
  g_dropped.fetch_add(1, std::memory_order_relaxed);
}

// One frame up the frame-pointer chain, if fp is on this thread's stack.
uint64_t CallerOf(uint64_t fp) {
  pthread_t self = pthread_self();
  uintptr_t top = uintptr_t(pthread_get_stackaddr_np(self));
  uintptr_t bottom = top - pthread_get_stacksize_np(self);
  if (fp < bottom || fp + 16 > top || (fp & 7)) return 0;
  return reinterpret_cast<const uint64_t*>(fp)[1];
}

void Chain(int sig, siginfo_t* info, void* context) {
  const struct sigaction& prev = sig == SIGBUS ? g_prev_bus : g_prev_segv;
  if (prev.sa_flags & SA_SIGINFO) {
    prev.sa_sigaction(sig, info, context);
  } else if (prev.sa_handler != SIG_DFL && prev.sa_handler != SIG_IGN) {
    prev.sa_handler(sig);
  } else {
    signal(sig, SIG_DFL);  // the re-executed fault then crashes as it would have
  }
}

void OnFault(int sig, siginfo_t* info, void* context) {
  uintptr_t addr = uintptr_t(info->si_addr);
  if (g_active.load(std::memory_order_acquire)) {
    for (int p = 0; p < g_page_count; ++p) {
      if (addr < g_pages[p] || addr >= g_pages[p] + g_page_size) continue;
      // Every store on the page is recorded, inside the viewport or not: the code that writes
      // its neighbours (the rest of the camera object) is as useful as the viewport's own writer.
      int nearest = 0;
      for (int r = 1; r < g_range_count; ++r) {
        if ((g_ranges[r].begin > addr ? g_ranges[r].begin - addr : addr - g_ranges[r].begin) <
            (g_ranges[nearest].begin > addr ? g_ranges[nearest].begin - addr
                                            : addr - g_ranges[nearest].begin))
          nearest = r;
      }
      const Range& r = g_ranges[nearest];
      bool inside = addr >= r.begin && addr < r.end;
      (inside ? g_viewport_faults : g_other_faults).fetch_add(1, std::memory_order_relaxed);
      auto* uc = static_cast<ucontext_t*>(context);
      Record(uc->uc_mcontext->__ss.__pc, uc->uc_mcontext->__ss.__lr,
             CallerOf(uc->uc_mcontext->__ss.__fp), uint32_t(nearest),
             uint32_t(int64_t(addr) - int64_t(r.begin)) + kBias);
      mprotect(reinterpret_cast<void*>(g_pages[p]), g_page_size, PROT_READ | PROT_WRITE);
      g_rearm.store(true, std::memory_order_release);
      return;
    }
  }
  Chain(sig, info, context);
}

bool PageWritable(uintptr_t page) {
  mach_vm_address_t addr = page;
  mach_vm_size_t size = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                     reinterpret_cast<vm_region_info_t>(&info), &count, &object) != KERN_SUCCESS)
    return false;
  return addr <= page && (info.protection & VM_PROT_WRITE);
}

std::string Where(uint64_t pc) {
  if (!pc) return "-";
  Dl_info info{};
  if (!dladdr(reinterpret_cast<void*>(pc), &info) || !info.dli_fbase)
    return fmt::format("0x{:X}", pc);
  const char* name = info.dli_fname ? std::strrchr(info.dli_fname, '/') : nullptr;
  name = name ? name + 1 : (info.dli_fname ? info.dli_fname : "?");
  std::string out = fmt::format("{}+0x{:X}", name, pc - uint64_t(uintptr_t(info.dli_fbase)));
  if (info.dli_sname) out += fmt::format(" ({})", info.dli_sname);
  return out;
}

void Run(int delay_seconds) {
  std::this_thread::sleep_for(std::chrono::seconds(delay_seconds));
  g_page_size = size_t(getpagesize());
  uint8_t* base = REX_KERNEL_MEMORY()->virtual_membase();
  const uint32_t guest = REXCVAR_GET(gtav_vr_watch_guest);
  const int armed_prot = REXCVAR_GET(gtav_vr_watch_reads) ? PROT_NONE : PROT_READ;
  std::vector<uint32_t> viewports;
  std::vector<uint32_t> blocks;  // 64-byte guest blocks
  if (guest) blocks.push_back(guest);
  if (REXCVAR_GET(gtav_vr_watch_source)) {
    // The game's viewports: an array of pointers at 0x839FF470 + 2144, its count at + 2148.
    // Each holds its grcViewport at + 16, whose camera matrix is at + 192.
    const uint8_t* mgr = rex::memory::GuestPtr(base, 0x839FF470u);
    uint32_t list = LoadBE(mgr + 2144);
    uint32_t count = uint32_t(mgr[2148]) << 8 | mgr[2149];
    for (uint32_t i = 0; i < count && i < kMaxViewports; ++i) {
      uint32_t vp = LoadBE(rex::memory::GuestPtr(base, list + 4 * i));
      if (!vp) continue;
      const uint8_t* m = rex::memory::GuestPtr(base, vp + 16 + 192);
      REXLOG_INFO("[vr] game viewport {} at 0x{:08X}: forward ({:.3f} {:.3f} {:.3f})", i, vp,
                  FloatBE(m + 32), FloatBE(m + 36), FloatBE(m + 40));
      blocks.push_back(vp + 16 + 192);
    }
  }
  if (!blocks.empty()) {
    // Blocks anywhere in guest memory, through the address the game uses.
    for (uint32_t g : blocks) {
      uintptr_t begin = uintptr_t(rex::memory::GuestPtr(base, g));
      g_ranges[g_range_count++] = {begin, begin + 64, g, 0};
      for (uintptr_t page = begin & ~(g_page_size - 1); page < begin + 64; page += g_page_size)
        if (std::find(g_pages, g_pages + g_page_count, page) == g_pages + g_page_count)
          g_pages[g_page_count++] = page;
    }
  } else {
    viewports = FindViewports();
    if (viewports.empty()) {
      REXLOG_WARN("[vr] no render viewport found in guest physical memory");
      return;
    }
  }
  for (uint32_t phys : viewports) {
    for (uint32_t view : kViewBases) {
      uintptr_t begin = uintptr_t(base) + view + phys;
      g_ranges[g_range_count++] = {begin, begin + kViewportBytes, phys, view};
      for (uintptr_t page = begin & ~(g_page_size - 1); page < begin + kViewportBytes;
           page += g_page_size) {
        if (std::find(g_pages, g_pages + g_page_count, page) != g_pages + g_page_count) continue;
        if (!PageWritable(page)) {
          REXLOG_WARN("[vr] view 0x{:08X} page of phys 0x{:08X} is not writable; not watched", view,
                      phys);
          continue;
        }
        g_pages[g_page_count++] = page;
      }
    }
  }

  struct sigaction sa {};
  sa.sa_sigaction = OnFault;
  sa.sa_flags = SA_SIGINFO;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &g_prev_bus);
  sigaction(SIGSEGV, &sa, &g_prev_segv);

  auto protect = [](int prot) {
    for (int p = 0; p < g_page_count; ++p)
      mprotect(reinterpret_cast<void*>(g_pages[p]), g_page_size, prot);
  };
  std::vector<uint8_t> before(viewports.size() * kViewportBytes);
  for (size_t i = 0; i < viewports.size(); ++i)
    std::memcpy(before.data() + i * kViewportBytes,
                REX_KERNEL_MEMORY()->TranslatePhysical(viewports[i]), kViewportBytes);
  g_active.store(true, std::memory_order_release);
  protect(armed_prot);
  REXLOG_INFO("[vr] watching {} viewport(s), {} host page(s), for {} s", viewports.size(),
              g_page_count, REXCVAR_GET(gtav_vr_watch_seconds));
  auto end = std::chrono::steady_clock::now() + std::chrono::seconds(REXCVAR_GET(gtav_vr_watch_seconds));
  while (std::chrono::steady_clock::now() < end) {
    std::this_thread::sleep_for(std::chrono::microseconds(100));
    if (g_rearm.exchange(false, std::memory_order_acq_rel)) protect(armed_prot);
  }
  g_active.store(false, std::memory_order_release);
  protect(PROT_READ | PROT_WRITE);
  // The handler stays installed (a signal may still be on its way to it); inactive, it only
  // passes faults on.

  for (size_t i = 0; i < viewports.size(); ++i) {
    const uint8_t* now = REX_KERNEL_MEMORY()->TranslatePhysical(viewports[i]);
    int changed = 0;
    for (uint32_t o = 0; o < kViewportBytes; o += 4)
      changed += std::memcmp(now + o, before.data() + i * kViewportBytes + o, 4) != 0;
    REXLOG_INFO("[vr] viewport phys 0x{:08X}: {} of 22 floats changed during the watch", viewports[i],
                changed);
  }
  std::vector<const Hit*> hits;
  for (const Hit& h : g_hits)
    if (h.key.load() && h.count.load()) hits.push_back(&h);
  std::sort(hits.begin(), hits.end(),
            [](const Hit* a, const Hit* b) { return a->count.load() > b->count.load(); });
  REXLOG_INFO("[vr] {} accessor(s) on the watched pages; {} faults in the block, {} beside it, {} "
              "dropped", hits.size(), g_viewport_faults.load(), g_other_faults.load(), g_dropped.load());
  for (size_t i = 0; i < hits.size() && i < 40; ++i) {
    const Hit& h = *hits[i];
    const Range& r = g_ranges[h.range.load()];
    int32_t lo = int32_t(h.lo.load() - kBias), hi = int32_t(h.hi.load() - kBias);
    bool inside = hi >= 0 && lo < int32_t(r.end - r.begin);
    REXLOG_INFO("[vr] {} {} accesses, bytes {}..{} from 0x{:08X} via 0x{:08X}: pc {} lr {} caller {}",
                inside ? '*' : ' ', h.count.load(), lo, hi, r.phys, r.view, Where(h.pc), Where(h.lr),
                Where(h.caller));
  }
}

}  // namespace

void OnFirstLoad() {
  int32_t delay = REXCVAR_GET(gtav_vr_watch_camera);
  if (delay <= 0) return;
  std::thread(Run, delay).detach();
}

}  // namespace gtav::native::camera_watch

#else

namespace gtav::native::camera_watch {
void OnFirstLoad() {
  if (REXCVAR_GET(gtav_vr_watch_camera) > 0)
    REXLOG_WARN("[vr] --gtav_vr_watch_camera is only implemented on macOS arm64");
}
}  // namespace gtav::native::camera_watch

#endif
