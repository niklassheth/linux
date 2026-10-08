// SPDX-License-Identifier: MIT
/* copy_burst: headless Vulkan test that records bursts of
 * vkCmdCopyBufferToImage (each one a meta compute dispatch in hk on Apple9),
 * modelled on Dota's loading trace: per image, barrier to TRANSFER_DST, one
 * copy per mip, barrier to SHADER_READ_ONLY. Each submit waits on a fence with
 * a timeout and reports STALL if the GPU doesn't finish.
 *
 *   copy_burst [--images N] [--size S] [--mips M] [--format rgba8|bc1|bc3|bc7|r8]
 *              [--submits K] [--timeout-ms T] [--recreate] [--split]
 * --split submits every image in its own command buffer within one vkQueueSubmit.
 * --interleave adds, after each image's copies, a clear-only 64x64 RGBA8 render
 * pass that the next copy waits on (compute->render->compute barriers), like
 * Dota's loading frames. --queues 2 alternates submits between two queues.
 * --inflight N keeps N submits in flight (ring of command buffer sets and
 * fences) instead of waiting for each one, so unretired Works can pass 128.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
   fprintf(stderr, "%s:%d %s = %d\n", __FILE__, __LINE__, #x, r_); exit(2); } } while (0)

static double now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
   unsigned images = 256, size = 256, mips = 9, submits = 200, timeout_ms = 5000;
   int recreate = 0, split = 0, interleave = 0; unsigned nqueues = 1, inflight = 1;
   const char *fmt_name = "bc3";
   for (int i = 1; i < argc; ++i) {
      if (!strcmp(argv[i], "--images") && i + 1 < argc) images = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--size") && i + 1 < argc) size = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--mips") && i + 1 < argc) mips = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--format") && i + 1 < argc) fmt_name = argv[++i];
      else if (!strcmp(argv[i], "--submits") && i + 1 < argc) submits = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--recreate")) recreate = 1;
      else if (!strcmp(argv[i], "--split")) split = 1;
      else if (!strcmp(argv[i], "--interleave")) interleave = 1;
      else if (!strcmp(argv[i], "--inflight") && i + 1 < argc) inflight = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--queues") && i + 1 < argc) nqueues = atoi(argv[++i]);
      else { fprintf(stderr, "bad arg %s\n", argv[i]); return 64; }
   }
   VkFormat format; unsigned block = 1, bpb = 4;
   if (!strcmp(fmt_name, "rgba8")) format = VK_FORMAT_R8G8B8A8_UNORM;
   else if (!strcmp(fmt_name, "r8")) { format = VK_FORMAT_R8_UNORM; bpb = 1; }
   else if (!strcmp(fmt_name, "bc1")) { format = VK_FORMAT_BC1_RGBA_SRGB_BLOCK; block = 4; bpb = 8; }
   else if (!strcmp(fmt_name, "bc3")) { format = VK_FORMAT_BC3_SRGB_BLOCK; block = 4; bpb = 16; }
   else if (!strcmp(fmt_name, "bc7")) { format = VK_FORMAT_BC7_SRGB_BLOCK; block = 4; bpb = 16; }
   else { fprintf(stderr, "bad format\n"); return 64; }
   unsigned max_mips = 1;
   while ((size >> max_mips) >= 1 && max_mips < 16) max_mips++;
   if (mips > max_mips) mips = max_mips;

   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "copy_burst", .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app };
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd;
   vkEnumeratePhysicalDevices(inst, &n, &pd);
   if (!n) { fprintf(stderr, "no device\n"); return 2; }
   VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
   printf("device %s driver 0x%x\n", props.deviceName, props.driverVersion);
   float prio = 1;
   float prios[2] = { 1, 1 };
   (void)prio;
   if (nqueues < 1) nqueues = 1;
   if (nqueues > 2) nqueues = 2;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0, .queueCount = nqueues, .pQueuePriorities = prios };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .synchronization2 = VK_TRUE, .dynamicRendering = VK_TRUE };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
   VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue qs[2]; vkGetDeviceQueue(dev, 0, 0, &qs[0]);
   if (nqueues > 1) vkGetDeviceQueue(dev, 0, 1, &qs[1]);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);

   /* Staging buffer holding the whole mip chain. */
   VkDeviceSize offsets[16], total = 0;
   for (unsigned m = 0; m < mips; ++m) {
      unsigned w = size >> m ? size >> m : 1;
      unsigned bw = (w + block - 1) / block;
      offsets[m] = total;
      total += (VkDeviceSize)bw * bw * bpb;
      total = (total + 15) & ~15ull;
   }
   VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = total,
      .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT };
   VkBuffer buf; CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
   VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, buf, &mr);
   uint32_t hv = UINT32_MAX, dl = UINT32_MAX;
   for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
      VkMemoryPropertyFlags f = mp.memoryTypes[i].propertyFlags;
      if (hv == UINT32_MAX && (mr.memoryTypeBits & (1u << i)) &&
          (f & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
             (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
         hv = i;
   }
   VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mr.size, .memoryTypeIndex = hv };
   VkDeviceMemory bmem; CHECK(vkAllocateMemory(dev, &mai, NULL, &bmem));
   CHECK(vkBindBufferMemory(dev, buf, bmem, 0));
   uint8_t *p; CHECK(vkMapMemory(dev, bmem, 0, total, 0, (void **)&p));
   uint32_t s = 12345;
   for (VkDeviceSize i = 0; i < total; ++i) { s = s * 1664525u + 1013904223u; p[i] = s >> 24; }

   VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = { size, size, 1 },
      .mipLevels = mips, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT };
   VkImage *img = calloc(images, sizeof(*img));
   VkDeviceMemory *imem = calloc(images, sizeof(*imem));
   #define CREATE_IMAGES() do { for (unsigned i = 0; i < images; ++i) { \
      CHECK(vkCreateImage(dev, &ii, NULL, &img[i])); \
      VkMemoryRequirements r; vkGetImageMemoryRequirements(dev, img[i], &r); \
      if (dl == UINT32_MAX) for (uint32_t t = 0; t < mp.memoryTypeCount; ++t) \
         if ((r.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { dl = t; break; } \
      VkMemoryAllocateInfo a = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = r.size, .memoryTypeIndex = dl }; \
      CHECK(vkAllocateMemory(dev, &a, NULL, &imem[i])); CHECK(vkBindImageMemory(dev, img[i], imem[i], 0)); } } while (0)
   #define DESTROY_IMAGES() do { for (unsigned i = 0; i < images; ++i) { \
      vkDestroyImage(dev, img[i], NULL); vkFreeMemory(dev, imem[i], NULL); } } while (0)
   CREATE_IMAGES();

   /* Small color target for --interleave passes. */
   VkImageCreateInfo rti = ii;
   rti.format = VK_FORMAT_R8G8B8A8_UNORM; rti.extent = (VkExtent3D){ 64, 64, 1 }; rti.mipLevels = 1;
   rti.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
   VkImage rt; CHECK(vkCreateImage(dev, &rti, NULL, &rt));
   VkDeviceMemory rtmem;
   {
      VkMemoryRequirements r; vkGetImageMemoryRequirements(dev, rt, &r);
      VkMemoryAllocateInfo a = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = r.size, .memoryTypeIndex = dl };
      CHECK(vkAllocateMemory(dev, &a, NULL, &rtmem)); CHECK(vkBindImageMemory(dev, rt, rtmem, 0));
   }
   VkImageViewCreateInfo rtv = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = rt,
      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
      .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   VkImageView rtview; CHECK(vkCreateImageView(dev, &rtv, NULL, &rtview));

   VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
   VkCommandPool pool; CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
   unsigned ncb = split ? images : 1;
   if (inflight < 1) inflight = 1;
   if (inflight > 64) inflight = 64;
   if (recreate && inflight > 1) { fprintf(stderr, "--recreate needs --inflight 1\n"); return 64; }
   VkCommandBuffer *cbs = calloc((size_t)ncb * inflight, sizeof(*cbs));
   VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = ncb * inflight };
   CHECK(vkAllocateCommandBuffers(dev, &cai, cbs));
   VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
   VkFence fences[64];
   for (unsigned f = 0; f < inflight; ++f) CHECK(vkCreateFence(dev, &fci, NULL, &fences[f]));

   printf("images=%u size=%u mips=%u format=%s submits=%u split=%d recreate=%d interleave=%d queues=%u inflight=%u copies/submit=%u\n",
          images, size, mips, fmt_name, submits, split, recreate, interleave, nqueues, inflight, images * mips);
   fflush(stdout);
   double t0 = now();
   for (unsigned k = 0; k < submits; ++k) {
      if (recreate && k) { DESTROY_IMAGES(); CREATE_IMAGES(); }
      unsigned slot = k % inflight;
      VkCommandBuffer *cb = cbs + (size_t)slot * ncb;
      VkFence fence = fences[slot];
      double tw = now();
      VkResult wr = vkWaitForFences(dev, 1, &fence, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
      if (wr != VK_SUCCESS) {
         printf("STALL waiting slot %u before submit=%u result=%d after %.3f s (t=%.3f)\n", slot, k, wr, now() - tw, now() - t0);
         fflush(stdout);
         return 1;
      }
      CHECK(vkResetFences(dev, 1, &fence));
      for (unsigned c = 0; c < ncb; ++c) {
         VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
         CHECK(vkBeginCommandBuffer(cb[c], &bi));
         unsigned first = split ? c : 0, last = split ? c + 1 : images;
         for (unsigned i = first; i < last; ++i) {
            VkImageMemoryBarrier2 b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
               .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
               .dstStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
               .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
               .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
               .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
               .image = img[i],
               .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, mips, 0, 1 } };
            VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
               .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b };
            vkCmdPipelineBarrier2(cb[c], &di);
            for (unsigned m = 0; m < mips; ++m) {
               unsigned w = size >> m ? size >> m : 1;
               VkBufferImageCopy r = { .bufferOffset = offsets[m],
                  .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, m, 0, 1 },
                  .imageExtent = { w, w, 1 } };
               vkCmdCopyBufferToImage(cb[c], buf, img[i], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
            }
            b.srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT;
            b.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
            b.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
            b.dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
            b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            b.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            vkCmdPipelineBarrier2(cb[c], &di);
            if (interleave) {
               /* copy -> render: the clear waits on the copies, and the
                * next image's copies wait on the clear. */
               VkImageMemoryBarrier2 rb = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                  .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                  .srcAccessMask = VK_ACCESS_2_MEMORY_WRITE_BIT,
                  .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                  .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                  .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                  .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                  .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                  .image = rt, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
               VkDependencyInfo rdi = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                  .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &rb };
               vkCmdPipelineBarrier2(cb[c], &rdi);
               VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                  .imageView = rtview, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                  .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                  .clearValue.color.float32 = { i * 0.01f, 0.5f, 0.25f, 1 } };
               VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
                  .renderArea = { { 0, 0 }, { 64, 64 } }, .layerCount = 1,
                  .colorAttachmentCount = 1, .pColorAttachments = &att };
               vkCmdBeginRendering(cb[c], &ri);
               vkCmdEndRendering(cb[c]);
               VkMemoryBarrier2 mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
                  .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                  .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                  .dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                  .dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT };
               VkDependencyInfo mdi = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                  .memoryBarrierCount = 1, .pMemoryBarriers = &mb };
               vkCmdPipelineBarrier2(cb[c], &mdi);
            }
         }
         CHECK(vkEndCommandBuffer(cb[c]));
      }
      VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = ncb, .pCommandBuffers = cb };
      double ts = now();
      CHECK(vkQueueSubmit(qs[k % nqueues], 1, &si, fence));
      if (inflight == 1) {
         VkResult r = vkWaitForFences(dev, 1, &fence, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
         double te = now();
         if (r != VK_SUCCESS) {
            printf("STALL submit=%u result=%d after %.3f s (t=%.3f)\n", k, r, te - ts, te - t0);
            fflush(stdout);
            return 1;
         }
         if (k % 20 == 0 || k + 1 == submits)
            printf("submit %u ok %.1f ms (t=%.3f)\n", k, (te - ts) * 1e3, te - t0);
      } else if (k % 20 == 0 || k + 1 == submits) {
         printf("submit %u queued (t=%.3f)\n", k, now() - t0);
      }
      fflush(stdout);
   }
   VkResult fr = vkWaitForFences(dev, inflight, fences, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
   if (fr != VK_SUCCESS) {
      printf("STALL draining result=%d (t=%.3f)\n", fr, now() - t0);
      return 1;
   }
   printf("PASS %u submits in %.3f s\n", submits, now() - t0);
   return 0;
}
