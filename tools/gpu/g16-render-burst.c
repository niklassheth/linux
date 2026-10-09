#include <unistd.h>
// SPDX-License-Identifier: MIT
/* render_burst: headless Vulkan test modelled on Dota's loading-phase stall:
 * chains of tiny dependent render passes on one queue. Each pass is one
 * full-screen draw (gpu_contend's fs.vert + a.frag) into the same attachment
 * with LOAD (or CLEAR) / STORE and optional src-alpha blending, followed by a
 * color->color barrier so the next pass depends on it. Submits are pipelined
 * (--inflight), each fence wait has a timeout that reports STALL.
 *
 *   render_burst [--passes N] [--width W --height H] [--format srgb|unorm]
 *                [--clear] [--blend 0|1] [--inflight K] [--submits S]
 *                [--work R] [--timeout-ms T] [--seconds S] [--instances N]
 *                [--burst B --idle-ms I]  (drain + sleep I ms after every B submits)
 *                [--pre-compute C --compute-iters N --compute-groups G]  (C compute Works right before each post-idle burst)
 * --instances N draws N overlapping full-screen triangles per pass, so tile
 * lists overflow the tiler heap and the firmware must do partial renders.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include "spirv.h"
#include "spin.h"

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
   fprintf(stderr, "%s:%d %s = %d\n", __FILE__, __LINE__, #x, r_); exit(2); } } while (0)

struct pc { uint32_t draw, work, frame; };

static double now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
   unsigned passes = 8, width = 1280, height = 720, inflight = 4, submits = 100000;
   unsigned work = 0, timeout_ms = 5000, seconds = 60, instances = 1, burst = 0, idle_ms = 0;
   unsigned pre_compute = 0, compute_iters = 20000, compute_groups = 256;
   bool clear = false, blend = true, srgb = true;
   for (int i = 1; i < argc; ++i) {
      if (!strcmp(argv[i], "--passes") && i + 1 < argc) passes = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--width") && i + 1 < argc) width = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--height") && i + 1 < argc) height = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--format") && i + 1 < argc) srgb = !strcmp(argv[++i], "srgb");
      else if (!strcmp(argv[i], "--clear")) clear = true;
      else if (!strcmp(argv[i], "--blend") && i + 1 < argc) blend = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--inflight") && i + 1 < argc) inflight = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--submits") && i + 1 < argc) submits = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--burst") && i + 1 < argc) burst = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--idle-ms") && i + 1 < argc) idle_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--pre-compute") && i + 1 < argc) pre_compute = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--compute-iters") && i + 1 < argc) compute_iters = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--compute-groups") && i + 1 < argc) compute_groups = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--work") && i + 1 < argc) work = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--instances") && i + 1 < argc) instances = atoi(argv[++i]);
      else { fprintf(stderr, "bad arg %s\n", argv[i]); return 64; }
   }
   if (inflight < 1) inflight = 1;
   if (inflight > 16) inflight = 16;
   VkFormat format = srgb ? VK_FORMAT_B8G8R8A8_SRGB : VK_FORMAT_R8G8B8A8_UNORM;

   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "render_burst", .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd;
   vkEnumeratePhysicalDevices(inst, &n, &pd);
   if (!n) { fprintf(stderr, "no device\n"); return 2; }
   VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
   printf("device %s driver 0x%x\n", props.deviceName, props.driverVersion);
   float prio = 1;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .synchronization2 = VK_TRUE, .dynamicRendering = VK_TRUE };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
   VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);

   /* Attachment: optimal tiling, COLOR | SAMPLED | TRANSFER_SRC (compressible). */
   VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = { width, height, 1 },
      .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
   VkImage img; CHECK(vkCreateImage(dev, &ii, NULL, &img));
   VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, img, &mr);
   uint32_t dl = UINT32_MAX;
   for (uint32_t t = 0; t < mp.memoryTypeCount; ++t)
      if ((mr.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { dl = t; break; }
   VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = dl };
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
   CHECK(vkBindImageMemory(dev, img, mem, 0));
   VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format,
      .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   VkImageView view; CHECK(vkCreateImageView(dev, &vci, NULL, &view));

   /* Pipeline. */
   VkShaderModuleCreateInfo smv = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = sizeof(spv_fs_vert), .pCode = spv_fs_vert };
   VkShaderModuleCreateInfo smf = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = sizeof(spv_a_frag), .pCode = spv_a_frag };
   VkShaderModule vs, fs; CHECK(vkCreateShaderModule(dev, &smv, NULL, &vs)); CHECK(vkCreateShaderModule(dev, &smf, NULL, &fs));
   VkPushConstantRange pcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(struct pc) };
   VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
   VkPipelineLayout layout; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
   VkPipelineShaderStageCreateInfo stages[2] = {
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" } };
   VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
   VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
   VkPipelineViewportStateCreateInfo vps = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1, .scissorCount = 1 };
   VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1 };
   VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
   VkPipelineColorBlendAttachmentState att = { .blendEnable = blend,
      .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA, .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
      .colorBlendOp = VK_BLEND_OP_ADD, .srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
      .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = VK_BLEND_OP_ADD,
      .colorWriteMask = 7 /* RGB only, as Dota's pass */ };
   VkPipelineColorBlendStateCreateInfo cbs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1, .pAttachments = &att };
   VkDynamicState dyn[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
   VkPipelineDynamicStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
      .dynamicStateCount = 2, .pDynamicStates = dyn };
   VkPipelineRenderingCreateInfo rci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
      .colorAttachmentCount = 1, .pColorAttachmentFormats = &format };
   VkGraphicsPipelineCreateInfo gci = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rci,
      .stageCount = 2, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
      .pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms,
      .pColorBlendState = &cbs, .pDynamicState = &ds, .layout = layout };
   VkPipeline pipe; CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gci, NULL, &pipe));

   VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
   VkCommandPool pool; CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
   VkCommandBuffer cbs_[16];
   VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = inflight };
   CHECK(vkAllocateCommandBuffers(dev, &cai, cbs_));
   /* Optional compute Works submitted right before each post-idle render burst (Dota's loading-end shape: 2-3 compute
    * Works back-to-back, then the renders, from one client, no semaphores between them). */
   if (pre_compute > 4) pre_compute = 4;
   VkCommandBuffer ccb[4]; VkFence cfence[4];
   if (pre_compute) {
      VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = (VkDeviceSize)compute_groups * 64 * 4,
         .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
      VkBuffer cbuf; CHECK(vkCreateBuffer(dev, &bci, NULL, &cbuf));
      VkMemoryRequirements bmr; vkGetBufferMemoryRequirements(dev, cbuf, &bmr);
      uint32_t bt = UINT32_MAX;
      for (uint32_t t = 0; t < mp.memoryTypeCount; ++t)
         if ((bmr.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { bt = t; break; }
      VkMemoryAllocateInfo bmai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = bmr.size, .memoryTypeIndex = bt };
      VkDeviceMemory bmem; CHECK(vkAllocateMemory(dev, &bmai, NULL, &bmem)); CHECK(vkBindBufferMemory(dev, cbuf, bmem, 0));
      VkDescriptorSetLayoutBinding lb = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
      VkDescriptorSetLayoutCreateInfo dlci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb };
      VkDescriptorSetLayout dsl; CHECK(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dsl));
      VkDescriptorPoolSize dps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
      VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &dps };
      VkDescriptorPool dpool; CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
      VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
      VkDescriptorSet dset; CHECK(vkAllocateDescriptorSets(dev, &dsai, &dset));
      VkDescriptorBufferInfo dbi = { cbuf, 0, VK_WHOLE_SIZE };
      VkWriteDescriptorSet wds = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = dset, .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
      vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);
      VkPushConstantRange cpr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 };
      VkPipelineLayoutCreateInfo cplci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
         .pSetLayouts = &dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &cpr };
      VkPipelineLayout clayout; CHECK(vkCreatePipelineLayout(dev, &cplci, NULL, &clayout));
      VkShaderModuleCreateInfo smc = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(spv_spin_comp), .pCode = spv_spin_comp };
      VkShaderModule cs; CHECK(vkCreateShaderModule(dev, &smc, NULL, &cs));
      VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = cs, .pName = "main" },
         .layout = clayout };
      VkPipeline cpipe; CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &cpipe));
      VkCommandBufferAllocateInfo ccai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
         .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = pre_compute };
      CHECK(vkAllocateCommandBuffers(dev, &ccai, ccb));
      VkFenceCreateInfo cfci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
      for (unsigned c = 0; c < pre_compute; ++c) {
         CHECK(vkCreateFence(dev, &cfci, NULL, &cfence[c]));
         VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
         CHECK(vkBeginCommandBuffer(ccb[c], &cbi));
         vkCmdBindPipeline(ccb[c], VK_PIPELINE_BIND_POINT_COMPUTE, cpipe);
         vkCmdBindDescriptorSets(ccb[c], VK_PIPELINE_BIND_POINT_COMPUTE, clayout, 0, 1, &dset, 0, NULL);
         uint32_t pcc[2] = { compute_iters, c };
         vkCmdPushConstants(ccb[c], clayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, pcc);
         vkCmdDispatch(ccb[c], compute_groups, 1, 1);
         CHECK(vkEndCommandBuffer(ccb[c]));
      }
   }
   VkFence fences[16];
   VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
   for (unsigned f = 0; f < inflight; ++f) CHECK(vkCreateFence(dev, &fci, NULL, &fences[f]));

   printf("passes=%u size=%ux%u format=%s load=%s blend=%d inflight=%u work=%u seconds=%u instances=%u\n",
          passes, width, height, srgb ? "B8G8R8A8_SRGB" : "R8G8B8A8_UNORM", clear ? "clear" : "load",
          blend, inflight, work, seconds, instances);
   fflush(stdout);
   double t0 = now(), last = t0;
   unsigned long total_passes = 0;
   for (unsigned k = 0; k < submits; ++k) {
      if (now() - t0 > seconds) break;
      /* Idle mode: after every `burst` submits, drain the GPU and sleep idle_ms (first render after a long idle). */
      if (burst && idle_ms && k && k % burst == 0) {
         VkResult dr = vkWaitForFences(dev, inflight, fences, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
         if (dr != VK_SUCCESS) { printf("STALL draining before idle at submit %u result=%d t=%.3f\n", k, dr, now() - t0); fflush(stdout); return 1; }
         if (pre_compute) {
            VkResult cr = vkWaitForFences(dev, pre_compute, cfence, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
            if (cr != VK_SUCCESS) { printf("STALL waiting compute before idle at submit %u result=%d\n", k, cr); fflush(stdout); return 1; }
            CHECK(vkResetFences(dev, pre_compute, cfence));
         }
         { struct timespec ts = { idle_ms / 1000, (long)(idle_ms % 1000) * 1000000L }; nanosleep(&ts, NULL); }
         for (unsigned c = 0; c < pre_compute; ++c) {
            VkSubmitInfo csi = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &ccb[c] };
            CHECK(vkQueueSubmit(q, 1, &csi, cfence[c]));
         }
         printf("burst %u after %u ms idle t=%.1f\n", k / burst, idle_ms, now() - t0); fflush(stdout);
      }
      unsigned slot = k % inflight;
      VkResult wr = vkWaitForFences(dev, 1, &fences[slot], VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
      if (wr != VK_SUCCESS) {
         printf("STALL waiting submit %u (slot %u) result=%d t=%.3f passes_done~%lu\n", k, slot, wr, now() - t0, total_passes);
         fflush(stdout);
         return 1;
      }
      CHECK(vkResetFences(dev, 1, &fences[slot]));
      VkCommandBuffer cb = cbs_[slot];
      VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
         .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
      CHECK(vkBeginCommandBuffer(cb, &bi));
      VkImageMemoryBarrier2 b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
         .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
         .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
         .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
         .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
         .oldLayout = k < inflight ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
         .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
         .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
         .image = img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
      VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b };
      for (unsigned p = 0; p < passes; ++p) {
         vkCmdPipelineBarrier2(cb, &di);
         b.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
         VkRenderingAttachmentInfo ra = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue.color.float32 = { 0.1f, 0.2f, 0.3f, 1 } };
         VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = { { 0, 0 }, { width, height } }, .layerCount = 1,
            .colorAttachmentCount = 1, .pColorAttachments = &ra };
         vkCmdBeginRendering(cb, &ri);
         vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
         VkViewport vpt = { 0, 0, (float)width, (float)height, 0, 1 };
         VkRect2D sc = { { 0, 0 }, { width, height } };
         vkCmdSetViewport(cb, 0, 1, &vpt); vkCmdSetScissor(cb, 0, 1, &sc);
         struct pc pcv = { p, work, k };
         vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(pcv), &pcv);
         vkCmdDraw(cb, 3, instances, 0, 0);
         vkCmdEndRendering(cb);
      }
      CHECK(vkEndCommandBuffer(cb));
      VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
      CHECK(vkQueueSubmit(q, 1, &si, fences[slot]));
      total_passes += passes;
      if (now() - last > 5) { last = now(); printf("t=%.1f submits=%u passes=%lu (%.0f passes/s)\n", last - t0, k + 1, total_passes, total_passes / (last - t0)); fflush(stdout); }
   }
   VkResult fr = vkWaitForFences(dev, inflight, fences, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
   if (fr != VK_SUCCESS) { printf("STALL draining result=%d\n", fr); return 1; }
   printf("PASS passes=%lu in %.1f s (%.0f passes/s)\n", total_passes, now() - t0, total_passes / (now() - t0));
   return 0;
}
