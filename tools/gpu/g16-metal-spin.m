// SPDX-License-Identifier: GPL-2.0-only
// Derived from our xhang.m Metal API workload; no Apple binary inspection.
// xhang.m: our own MSL; a GPU timeout under render contention, for firmware tracing.
//   xhang H <start_ms>  at start+3 s, commits one compute dispatch whose threads loop
//                       ~4e9 times (stores only on an unlikely value), logs the command
//                       buffer's completion status and error, then commits a short probe
//                       command buffer on the same queue and logs whether it completes.
//   xhang R <start_ms>  renders 128x64 frames from start to start+60 s, logging every
//                       completion gap > 50 ms and every error.
//   xhang C <start_ms>  like R, but small compute dispatches on its own queue.
// Public Metal API only. Build: clang -fobjc-arc -framework Metal -framework Foundation -o xhang xhang.m
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>

static const char *SRC =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void spin(device uint *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]])\n"
"{ uint x = i ^ 1u; for (uint k = 0; k < n; k++) { x = x * 1664525u + 1013904223u; } o[i] = x; }\n"
"kernel void probe(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i + 1; }\n"
"struct VO { float4 p [[position]]; float2 uv; };\n"
"vertex VO vs(uint v [[vertex_id]]) { VO o; float2 q = float2((v << 1) & 2, v & 2); o.p = float4(q * 2.0 - 1.0, 0, 1); o.uv = q; return o; }\n"
"fragment float4 fs(VO in [[stage_in]]) { return float4(in.uv, 0.5, 1); }\n";

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }
static void say(const char *tag, const char *fmt, NSError *e, double t)
{
   printf("%.3f %s %s%s%s\n", t, tag, fmt, e ? " error: " : "", e ? e.description.UTF8String : "");
   fflush(stdout);
}

/* Run finite H_ITERS controls before the long case. The shader's output
 * depends on every iteration. Same LCG, seed, grid and default local size as
 * our Vulkan gpu_fault_test; this version always stores its final value. */
static uint32_t setting(const char *name, uint32_t fallback, uint32_t maximum)
{
   const char *s = getenv(name);
   if (!s) return fallback;
   char *end = NULL; errno = 0;
   unsigned long long value = strtoull(s, &end, 0);
   if (errno || end == s || *end || !value || value > maximum) {
      fprintf(stderr, "invalid %s=%s\n", name, s); exit(64);
   }
   return (uint32_t)value;
}

/* Exponentiate the affine recurrence modulo 2^32 to check finite controls. */
static uint32_t expected(uint32_t x, uint32_t n)
{
   uint32_t scale = 1664525u, bias = 1013904223u;
   while (n) {
      if (n & 1) x = scale * x + bias;
      bias = scale * bias + bias;
      scale *= scale;
      n >>= 1;
   }
   return x;
}

int main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 3) { fprintf(stderr, "usage: xhang H|R start_ms\n"); return 1; }
      bool H = !strcmp(argv[1], "H");
      bool C = !strcmp(argv[1], "C");
      double start = atoll(argv[2]) / 1000.0;
      id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
      NSError *e = nil;
      id<MTLLibrary> lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
      if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
      id<MTLCommandQueue> q = [dev newCommandQueue];
      id<MTLBuffer> out = [dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
      if (H) {
         id<MTLComputePipelineState> spin = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"spin"] error:&e];
         id<MTLComputePipelineState> probe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"probe"] error:&e];
         while (now_s() < start + 3) usleep(1000);
         uint32_t n = setting("H_ITERS", UINT32_MAX, UINT32_MAX);
         uint32_t threads = setting("H_THREADS", 65536, (1 << 20) / 4);
         uint32_t group = setting("H_TG", 64, (uint32_t)spin.maxTotalThreadsPerThreadgroup);
         printf("H config iterations=%u threads=%u local=%u seed=1 final-store=yes\n", n, threads, group);
         fflush(stdout);
         memset(out.contents, 0xa5, out.length);
         id<MTLCommandBuffer> cb = [q commandBuffer];
         id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
         [c setComputePipelineState:spin]; [c setBuffer:out offset:0 atIndex:0]; [c setBytes:&n length:4 atIndex:1];
         [c dispatchThreads:MTLSizeMake(threads, 1, 1) threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];
         [c endEncoding];
         say("H", "commit spin", nil, now_s() - start);
         [cb commit];
         [cb waitUntilCompleted];
         say("H", cb.status == MTLCommandBufferStatusCompleted ? "spin completed" : "spin ended", cb.error, now_s() - start);
         printf("H spin status=%ld gpu=%.3f..%.3f\n", (long)cb.status, cb.GPUStartTime, cb.GPUEndTime);
         if (cb.status == MTLCommandBufferStatusCompleted) {
            unsigned bad = 0;
            uint32_t *values = out.contents;
            for (uint32_t i = 0; i < threads; ++i)
               bad += values[i] != expected(i ^ 1u, n);
            printf("H verify samples=%u mismatches=%u first=%08x expected=%08x\n",
                   threads, bad, values[0], expected(1, n));
            fflush(stdout);
            if (bad) return 2;
         }
         for (int r = 0; r < 3; ++r) {
            id<MTLCommandBuffer> pb = [q commandBuffer];
            id<MTLComputeCommandEncoder> pc = [pb computeCommandEncoder];
            [pc setComputePipelineState:probe]; [pc setBuffer:out offset:0 atIndex:0];
            [pc dispatchThreads:MTLSizeMake(1024, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [pc endEncoding];
            [pb commit]; [pb waitUntilCompleted];
            char m[96]; snprintf(m, sizeof(m), "probe %d status=%ld out[5]=%u", r, (long)pb.status, ((uint32_t *)out.contents)[5]);
            say("H", m, pb.error, now_s() - start);
         }
      } else if (C) {
         id<MTLComputePipelineState> probe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"probe"] error:&e];
         while (now_s() < start) usleep(1000);
         double last = now_s(); unsigned n = 0, errors = 0;
         while (now_s() < start + 60) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
            [c setComputePipelineState:probe]; [c setBuffer:out offset:0 atIndex:0];
            [c dispatchThreads:MTLSizeMake(4096, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [c endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            double t = now_s(); ++n;
            if (cb.error) { ++errors; say("C", "dispatch error", cb.error, t - start); }
            if (t - last > 0.05) { char m[64]; snprintf(m, sizeof(m), "gap %.3f s", t - last); say("C", m, nil, t - start); }
            last = t;
            usleep(4000);
         }
         printf("C dispatches=%u errors=%u\n", n, errors);
      } else {
         MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
         rd.vertexFunction = [lib newFunctionWithName:@"vs"];
         rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
         rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
         id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:rd error:&e];
         MTLTextureDescriptor *rtd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:128 height:64 mipmapped:NO];
         rtd.usage = MTLTextureUsageRenderTarget; rtd.storageMode = MTLStorageModePrivate;
         id<MTLTexture> rt = [dev newTextureWithDescriptor:rtd];
         while (now_s() < start) usleep(1000);
         double last = now_s(); unsigned frames = 0, errors = 0;
         while (now_s() < start + 60) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
            pd.colorAttachments[0].texture = rt; pd.colorAttachments[0].loadAction = MTLLoadActionClear;
            pd.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:pd];
            [r setRenderPipelineState:rp]; [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            double t = now_s(); ++frames;
            if (cb.error) { ++errors; say("R", "frame error", cb.error, t - start); }
            if (t - last > 0.05) { char m[64]; snprintf(m, sizeof(m), "gap %.3f s", t - last); say("R", m, nil, t - start); }
            last = t;
            usleep(4000);
         }
         printf("R frames=%u errors=%u\n", frames, errors);
      }
   }
   return 0;
}
