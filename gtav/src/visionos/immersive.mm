// gtav - visionOS immersive space: the compositor loop (docs/VISIONOS_PLAN.md, phase 2).
//
// Every display frame (90 Hz) it takes the predicted head pose from ARKit world tracking and draws
// the newest game frame, for each eye, onto a 16:9 screen fixed in the room: 3.2 m wide, 3 m in
// front of where the player looked when the space opened, at eye height. The game renders at its
// own rate; the newest frame it published is shown again until the next one arrives.
// Recentre: hold both sticks in (L3 + R3) for 0.75 s and the screen moves to where the player looks.
// Compiled with ARC.
#include "immersive.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#include <ARKit/ARKit.h>
#include <CompositorServices/CompositorServices.h>
#include <simd/simd.h>

#include <atomic>
#include <mutex>
#include <vector>

#include <rex/logging.h>

namespace {

constexpr float kScreenDistance = 3.0f;  // metres in front of the player
constexpr float kScreenHalfWidth = 1.6f;
constexpr float kScreenHalfHeight = 0.9f;
constexpr double kRecentreHoldSeconds = 0.75;

// The game frame is gamma-encoded in a UNORM texture and the drawable is sRGB: decode on read so
// the compositor's sRGB write encodes it back once. No game frame yet: a dim checkerboard.
const char* kShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
  float4x4 mvp;
  float4 params;  // x: 1 when the game frame is bound
};

struct VertexOut {
  float4 position [[position]];
  float2 uv;
};

vertex VertexOut screen_vs(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
  const float2 corners[6] = {float2(-1, -1), float2(1, -1), float2(-1, 1),
                             float2(-1, 1),  float2(1, -1), float2(1, 1)};
  float2 p = corners[vid];
  VertexOut out;
  out.position = u.mvp * float4(p, 0.0, 1.0);
  out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  return out;
}

fragment float4 screen_fs(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                          texture2d<float> game [[texture(0)]], sampler s [[sampler(0)]]) {
  float3 c;
  if (u.params.x > 0.5) {
    c = pow(game.sample(s, in.uv).rgb, 2.2);
  } else {
    float2 cell = floor(in.uv * float2(16.0, 9.0));
    c = fmod(cell.x + cell.y, 2.0) < 1.0 ? float3(0.03) : float3(0.08);
  }
  return float4(c, 1.0);
}
)";

struct Uniforms {
  simd_float4x4 mvp;
  simd_float4 params;
};

std::atomic<bool> g_active{false};
std::mutex g_game_mutex;
id<MTLTexture> g_game_texture = nil;

// The screen's transform in the world: facing the player, kScreenDistance along where they look
// (levelled), at their eye height.
simd_float4x4 PlaceScreen(simd_float4x4 head) {
  simd_float3 position = head.columns[3].xyz;
  simd_float3 forward = -head.columns[2].xyz;
  forward.y = 0.0f;
  forward = simd_length(forward) < 1e-3f ? simd_make_float3(0, 0, -1) : simd_normalize(forward);
  simd_float3 z = -forward;  // the screen's front faces the player
  simd_float3 y = simd_make_float3(0, 1, 0);
  simd_float3 x = simd_cross(y, z);
  simd_float3 center = position + forward * kScreenDistance;
  return simd_matrix(simd_make_float4(x, 0), simd_make_float4(y, 0), simd_make_float4(z, 0),
                     simd_make_float4(center, 1));
}

// Both sticks pressed on any connected controller (read directly, beside SDL's own reading).
bool RecentreButtonsHeld() {
  for (GCController* controller in GCController.controllers) {
    GCExtendedGamepad* pad = controller.extendedGamepad;
    if (pad && pad.leftThumbstickButton.isPressed && pad.rightThumbstickButton.isPressed) return true;
  }
  return false;
}

std::vector<cp_drawable_t> Drawables(cp_frame_t frame) {
  std::vector<cp_drawable_t> out;
  if (@available(visionOS 26.0, *)) {
    cp_drawable_array_t array = cp_frame_query_drawables(frame);
    for (size_t i = 0, n = cp_drawable_array_get_count(array); i < n; ++i)
      out.push_back(cp_drawable_array_get_drawable(array, i));
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (cp_drawable_t d = cp_frame_query_drawable(frame)) out.push_back(d);
#pragma clang diagnostic pop
  }
  return out;
}

}  // namespace

extern "C" bool gtav_immersive_active(void) { return g_active.load(); }

extern "C" void gtav_immersive_publish(void* mtl_texture) {
  std::lock_guard<std::mutex> lock(g_game_mutex);
  g_game_texture = (__bridge id<MTLTexture>)mtl_texture;
}

extern "C" void gtav_immersive_run(cp_layer_renderer_t layer) {
  id<MTLDevice> device = cp_layer_renderer_get_device(layer);
  id<MTLCommandQueue> queue = [device newCommandQueue];
  cp_layer_renderer_configuration_t config = cp_layer_renderer_get_configuration(layer);

  NSError* error = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:@(kShaderSource) options:nil error:&error];
  if (!library) {
    REXLOG_ERROR("[immersive] shader compile failed: {}", error.localizedDescription.UTF8String);
    return;
  }
  MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
  pd.vertexFunction = [library newFunctionWithName:@"screen_vs"];
  pd.fragmentFunction = [library newFunctionWithName:@"screen_fs"];
  pd.colorAttachments[0].pixelFormat = cp_layer_renderer_configuration_get_color_format(config);
  pd.depthAttachmentPixelFormat = cp_layer_renderer_configuration_get_depth_format(config);
  id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
  if (!pipeline) {
    REXLOG_ERROR("[immersive] pipeline failed: {}", error.localizedDescription.UTF8String);
    return;
  }
  MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionGreater;  // reverse Z: the compositor clears to 0
  dd.depthWriteEnabled = YES;
  id<MTLDepthStencilState> depth_state = [device newDepthStencilStateWithDescriptor:dd];
  MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];
  // Bound while there is no game frame yet (Metal wants a texture in the slot).
  MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                               width:1
                                                                              height:1
                                                                           mipmapped:NO];
  id<MTLTexture> placeholder = [device newTextureWithDescriptor:td];

  ar_session_t session = ar_session_create();
  ar_world_tracking_configuration_t world_config = ar_world_tracking_configuration_create();
  ar_world_tracking_provider_t world = ar_world_tracking_provider_create(world_config);
  ar_data_providers_t providers = ar_data_providers_create();
  ar_data_providers_add_data_provider(providers, world);
  ar_session_run(session, providers);

  REXLOG_INFO("[immersive] compositor loop started ({}, {} views per drawable)", device.name.UTF8String,
              cp_layer_renderer_configuration_get_layout(config) == cp_layer_renderer_layout_dedicated
                  ? "dedicated textures"
                  : "shared/layered");
  g_active = true;
  bool placed = false;
  simd_float4x4 screen = PlaceScreen(matrix_identity_float4x4);
  const simd_float4x4 scale = simd_matrix(simd_make_float4(kScreenHalfWidth, 0, 0, 0),
                                          simd_make_float4(0, kScreenHalfHeight, 0, 0),
                                          simd_make_float4(0, 0, 1, 0), simd_make_float4(0, 0, 0, 1));
  uint64_t frames = 0, tracked = 0;
  CFTimeInterval recentre_since = 0;  // when L3 + R3 went down; 0 while not held
  bool recentre_armed = true;         // one recentre per press

  for (bool running = true; running;) {
    @autoreleasepool {
      switch (cp_layer_renderer_get_state(layer)) {
        case cp_layer_renderer_state_paused:
          cp_layer_renderer_wait_until_running(layer);
          continue;
        case cp_layer_renderer_state_invalidated:
          running = false;
          continue;
        default:
          break;
      }
      cp_frame_t frame = cp_layer_renderer_query_next_frame(layer);
      if (!frame) continue;
      cp_frame_timing_t timing = cp_frame_predict_timing(frame);
      if (!timing) continue;
      cp_frame_start_update(frame);
      if (RecentreButtonsHeld()) {
        CFTimeInterval now = CACurrentMediaTime();
        if (!recentre_since) recentre_since = now;
        if (recentre_armed && now - recentre_since >= kRecentreHoldSeconds) {
          placed = false;  // placed again from the next tracked head pose
          recentre_armed = false;
        }
      } else {
        recentre_since = 0;
        recentre_armed = true;
      }
      cp_frame_end_update(frame);
      cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
      cp_frame_start_submission(frame);

      id<MTLTexture> game;
      {
        std::lock_guard<std::mutex> lock(g_game_mutex);
        game = g_game_texture;
      }
      id<MTLCommandBuffer> cmd = [queue commandBuffer];
      for (cp_drawable_t drawable : Drawables(frame)) {
        CFTimeInterval when =
            cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
        ar_device_anchor_t anchor = ar_device_anchor_create();
        simd_float4x4 head = matrix_identity_float4x4;
        if (ar_world_tracking_provider_query_device_anchor_at_timestamp(world, when, anchor) ==
            ar_device_anchor_query_status_success) {
          head = ar_anchor_get_origin_from_anchor_transform(anchor);
          cp_drawable_set_device_anchor(drawable, anchor);
          tracked++;
          if (!placed) {
            screen = PlaceScreen(head);
            placed = true;
            const float height = screen.columns[3].y;
            REXLOG_INFO("[immersive] screen placed {:.2f} m ahead at height {:.2f} m{}", kScreenDistance, height,
                        frames ? " (recentred)" : "");
          }
        }
        for (size_t v = 0, n = cp_drawable_get_view_count(drawable); v < n; ++v) {
          cp_view_t view = cp_drawable_get_view(drawable, v);
          cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
          size_t index = cp_view_texture_map_get_texture_index(map);
          simd_float4x4 view_matrix = simd_inverse(simd_mul(head, cp_view_get_transform(view)));
          simd_float4x4 projection =
              cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, v);
          Uniforms u;
          u.mvp = simd_mul(projection, simd_mul(view_matrix, simd_mul(screen, scale)));
          u.params = simd_make_float4(game ? 1.0f : 0.0f, 0, 0, 0);

          MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
          rp.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, index);
          rp.colorAttachments[0].loadAction = MTLLoadActionClear;
          rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
          rp.colorAttachments[0].storeAction = MTLStoreActionStore;
          rp.depthAttachment.texture = cp_drawable_get_depth_texture(drawable, index);
          rp.depthAttachment.loadAction = MTLLoadActionClear;
          rp.depthAttachment.clearDepth = 0.0;
          rp.depthAttachment.storeAction = MTLStoreActionStore;
          id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
          [enc setViewport:cp_view_texture_map_get_viewport(map)];
          [enc setRenderPipelineState:pipeline];
          [enc setDepthStencilState:depth_state];
          [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
          [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
          [enc setFragmentTexture:game ? game : placeholder atIndex:0];
          [enc setFragmentSamplerState:sampler atIndex:0];
          [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
          [enc endEncoding];
        }
        cp_drawable_encode_present(drawable, cmd);
      }
      [cmd commit];
      cp_frame_end_submission(frame);
      if (++frames % 900 == 0) {
        REXLOG_INFO("[immersive] {} frames, head tracked in {}, game frame {}", frames, tracked,
                    game ? "shown" : "not published yet");
      }
    }
  }
  g_active = false;
  REXLOG_INFO("[immersive] compositor loop ended after {} frames", frames);
}
