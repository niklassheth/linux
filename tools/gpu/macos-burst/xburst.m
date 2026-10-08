// xburst.m: our own MSL/Metal program reproducing the shape of Dota's loading-end burst, for firmware-queue
// tracing under the m1n1 HV (clean room: we observe only what our program makes the driver submit).
//   xburst one|split BURSTS    loading-like phase of small passes (298x452), then BURSTS bursts, each:
//                              CLEAR 1280x720 BGRA8-sRGB (uncompressed, fresh texture), 2x LOAD+blend RGB-mask
//                              1280x720 passes into it, then a LOAD 1920x1080 BGRA8-sRGB pass; "one" = one
//                              command buffer per burst, "split" = one command buffer per pass.
//   xburst client W H SECONDS  background client: back-to-back WxH passes, 2 per command buffer.
// Public Metal API only. Build: clang -fobjc-arc -O2 -framework Metal -framework Foundation -o xburst xburst.m
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static const char *SRC =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 p [[position]]; float2 uv; };\n"
"vertex VO vs(uint v [[vertex_id]]) { VO o; float2 q = float2((v << 1) & 2, v & 2); o.p = float4(q * 2.0 - 1.0, 0, 1); o.uv = q; return o; }\n"
"fragment float4 fs(VO in [[stage_in]], constant float &k [[buffer(0)]]) { return float4(in.uv * k, 0.5, 0.5); }\n";

static id<MTLDevice> dev;
static id<MTLRenderPipelineState> pipe(id<MTLLibrary> lib, MTLPixelFormat f, bool blend_rgb)
{
   MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
   d.vertexFunction = [lib newFunctionWithName:@"vs"];
   d.fragmentFunction = [lib newFunctionWithName:@"fs"];
   d.colorAttachments[0].pixelFormat = f;
   if (blend_rgb) {
      d.colorAttachments[0].blendingEnabled = YES;
      d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
      d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
      d.colorAttachments[0].writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
   }
   NSError *e = nil;
   id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
   if (!p) { fprintf(stderr, "pipeline: %s\n", e.localizedDescription.UTF8String); exit(1); }
   return p;
}
static id<MTLTexture> tex(MTLPixelFormat f, NSUInteger w, NSUInteger h, bool compress)
{
   MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
   d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   d.storageMode = MTLStorageModePrivate;
   d.allowGPUOptimizedContents = compress;
   return [dev newTextureWithDescriptor:d];
}
static void pass(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> p, id<MTLTexture> t, MTLLoadAction load, float k, NSString *label)
{
   MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
   d.colorAttachments[0].texture = t;
   d.colorAttachments[0].loadAction = load;
   d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
   d.colorAttachments[0].storeAction = MTLStoreActionStore;
   id<MTLRenderCommandEncoder> r = [cb renderCommandEncoderWithDescriptor:d];
   r.label = label;
   [r setRenderPipelineState:p];
   [r setFragmentBytes:&k length:sizeof(k) atIndex:0];
   [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
   [r endEncoding];
}
static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }

int main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 3) { fprintf(stderr, "usage: xburst one|split BURSTS | client W H SECONDS\n"); return 1; }
      dev = MTLCreateSystemDefaultDevice();
      NSError *e = nil;
      id<MTLLibrary> lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e];
      if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
      id<MTLCommandQueue> q = [dev newCommandQueue];
      const MTLPixelFormat SRGB = MTLPixelFormatBGRA8Unorm_sRGB;
      if (!strcmp(argv[1], "client")) {
         NSUInteger W = atoi(argv[2]), H = atoi(argv[3]); double secs = argc > 4 ? atof(argv[4]) : 30;
         id<MTLRenderPipelineState> p = pipe(lib, SRGB, false);
         id<MTLTexture> t = tex(SRGB, W, H, true);
         double t0 = now(); unsigned long n = 0; id<MTLCommandBuffer> cb = nil;
         while (now() - t0 < secs) {
            cb = [q commandBuffer];
            pass(cb, p, t, MTLLoadActionLoad, 0.5, @"client"); pass(cb, p, t, MTLLoadActionLoad, 0.7, @"client");
            [cb commit]; n += 2;
            if ((n % 16) == 0) [cb waitUntilCompleted];
         }
         [cb waitUntilCompleted];
         printf("client %lux%lu renders=%lu status=%ld\n", (unsigned long)W, (unsigned long)H, n, (long)cb.status);
         return 0;
      }
      bool split = !strcmp(argv[1], "split");
      unsigned bursts = atoi(argv[2]);
      id<MTLRenderPipelineState> pclear = pipe(lib, SRGB, false), pload = pipe(lib, SRGB, true);
      id<MTLTexture> small = tex(SRGB, 298, 452, true), big = tex(SRGB, 1920, 1080, false);
      id<MTLCommandBuffer> cb = nil;
      for (unsigned b = 0; b < bursts; b++) {
         /* Loading-like phase: ~0.5 s of small passes, as Dota's loading screen does before its burst. */
         double t0 = now();
         while (now() - t0 < 0.5) {
            cb = [q commandBuffer];
            for (int i = 0; i < 4; i++) pass(cb, pclear, small, i ? MTLLoadActionLoad : MTLLoadActionClear, 0.3, @"load-small");
            [cb commit]; [cb waitUntilCompleted];
            usleep(20000);
         }
         /* The burst: a fresh uncompressed 1280x720 sRGB intermediate, CLEAR then 2x LOAD+blend RGB-mask,
          * then the 1920x1080 LOAD pass. */
         id<MTLTexture> inter = tex(SRGB, 1280, 720, false);
         cb = [q commandBuffer];
         pass(cb, pclear, inter, MTLLoadActionClear, 1.0, @"burst-clear");
         if (split) { [cb commit]; cb = [q commandBuffer]; }
         pass(cb, pload, inter, MTLLoadActionLoad, 0.8, @"burst-load1");
         if (split) { [cb commit]; cb = [q commandBuffer]; }
         pass(cb, pload, inter, MTLLoadActionLoad, 0.6, @"burst-load2");
         if (split) { [cb commit]; cb = [q commandBuffer]; }
         pass(cb, pload, big, MTLLoadActionLoad, 0.4, @"burst-big");
         [cb commit]; [cb waitUntilCompleted];
      }
      printf("mode=%s bursts=%u status=%ld error=%s\n", argv[1], bursts, (long)cb.status,
             cb.error ? cb.error.localizedDescription.UTF8String : "none");
   }
   return 0;
}
