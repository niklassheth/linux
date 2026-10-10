// SPDX-License-Identifier: MIT
/* rc_bench: render->compute edge latency bench (Lethal/DXVK pattern).
 *
 * Each "frame" has N edges. One edge = a small render pass (one full-screen draw, fs.vert + a.frag) followed by a
 * compute dispatch (spin.comp) that depends on it, then a compute->graphics barrier so the next edge is serial too.
 *   --mode barrier    one vkQueueSubmit per frame; render->compute ordered by vkCmdPipelineBarrier2 in one command
 *                     buffer (DXVK within a submission)
 *   --mode semaphore  render and compute in separate submits; compute waits on a timeline semaphore the render signals
 * With --timestamps 1 (default), GPU timestamps around each pass give the render-end -> compute-start gap and the
 * compute-end -> next-render-start gap per edge; the report also gives frames/s and CPU frame time.
 *
 *   rc_bench [--mode barrier|semaphore] [--edges N] [--frames F] [--seconds S] [--width W --height H]
 *            [--compute-iters I] [--groups G] [--timestamps 0|1] [--timeout-ms T] [--r2c-src color|fragment|all] [--event]
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
#define MAX_EDGES 256

struct pc { uint32_t draw, work, frame; };

static double now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec + t.tv_nsec * 1e-9;
}

static int cmp_d(const void *a, const void *b)
{
   double x = *(const double *)a, y = *(const double *)b;
   return x < y ? -1 : x > y;
}

static void stats(const char *name, double *v, size_t n)
{
   if (!n) { printf("%s: no samples\n", name); return; }
   qsort(v, n, sizeof(*v), cmp_d);
   double s = 0;
   for (size_t i = 0; i < n; ++i) s += v[i];
   printf("%s (us): n=%zu mean=%.2f p50=%.2f p90=%.2f p99=%.2f max=%.2f\n", name, n, s / n,
          v[n / 2], v[n * 9 / 10], v[n * 99 / 100], v[n - 1]);
}

int main(int argc, char **argv)
{
   unsigned edges = 16, frames = 1000, seconds = 30, width = 256, height = 256, iters = 64, groups = 16;
   unsigned timeout_ms = 5000;
   bool semaphore = false, timestamps = true, use_event = false; const char *r2c_src = "color";
   for (int i = 1; i < argc; ++i) {
      if (!strcmp(argv[i], "--mode") && i + 1 < argc) semaphore = !strcmp(argv[++i], "semaphore");
      else if (!strcmp(argv[i], "--edges") && i + 1 < argc) edges = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--width") && i + 1 < argc) width = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--height") && i + 1 < argc) height = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--compute-iters") && i + 1 < argc) iters = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--groups") && i + 1 < argc) groups = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--timestamps") && i + 1 < argc) timestamps = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--r2c-src") && i + 1 < argc) r2c_src = argv[++i];
      else if (!strcmp(argv[i], "--event")) use_event = true;
      else { fprintf(stderr, "bad arg %s\n", argv[i]); return 64; }
   }
   if (edges < 1) edges = 1;
   if (edges > MAX_EDGES) edges = MAX_EDGES;

   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "rc_bench",
      .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   uint32_t n = 1; VkPhysicalDevice pd;
   vkEnumeratePhysicalDevices(inst, &n, &pd);
   if (!n) { fprintf(stderr, "no device\n"); return 2; }
   VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
   uint32_t nq = 1; VkQueueFamilyProperties qfp; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, &qfp);
   if (timestamps && (!qfp.timestampValidBits || props.limits.timestampPeriod == 0)) {
      printf("timestamps unsupported on queue family 0; disabling\n"); timestamps = false;
   }
   printf("r2c barrier: src=%s event=%d\n", r2c_src, use_event);
   printf("device %s driver 0x%x mode=%s edges/frame=%u size=%ux%u compute=%ux64 threads x %u iters ts_period=%.3f ns\n",
          props.deviceName, props.driverVersion, semaphore ? "semaphore" : "barrier", edges, width, height,
          groups, iters, props.limits.timestampPeriod);
   float prio = 1;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
   VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
      .timelineSemaphore = VK_TRUE, .hostQueryReset = VK_TRUE };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &f12,
      .synchronization2 = VK_TRUE, .dynamicRendering = VK_TRUE };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
   VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);

   /* Attachment. */
   VkFormat format = VK_FORMAT_R8G8B8A8_UNORM;
   VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
      .format = format, .extent = { width, height, 1 }, .mipLevels = 1, .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT };
   VkImage img; CHECK(vkCreateImage(dev, &ii, NULL, &img));
   VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, img, &mr);
   uint32_t dl = UINT32_MAX;
   for (uint32_t t = 0; t < mp.memoryTypeCount; ++t)
      if ((mr.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { dl = t; break; }
   VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = dl };
   VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem)); CHECK(vkBindImageMemory(dev, img, mem, 0));
   VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   VkImageView view; CHECK(vkCreateImageView(dev, &vci, NULL, &view));

   /* Graphics pipeline. */
   VkShaderModuleCreateInfo smv = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(spv_fs_vert), .pCode = spv_fs_vert };
   VkShaderModuleCreateInfo smf = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(spv_a_frag), .pCode = spv_a_frag };
   VkShaderModule vs, fs; CHECK(vkCreateShaderModule(dev, &smv, NULL, &vs)); CHECK(vkCreateShaderModule(dev, &smf, NULL, &fs));
   VkPushConstantRange pcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(struct pc) };
   VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
   VkPipelineLayout layout; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
   VkPipelineShaderStageCreateInfo stages[2] = {
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" } };
   VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
   VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
   VkPipelineViewportStateCreateInfo vps = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
   VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1 };
   VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
   VkPipelineColorBlendAttachmentState att = { .colorWriteMask = 0xf };
   VkPipelineColorBlendStateCreateInfo cbs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att };
   VkDynamicState dyn[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
   VkPipelineDynamicStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dyn };
   VkPipelineRenderingCreateInfo rci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1, .pColorAttachmentFormats = &format };
   VkGraphicsPipelineCreateInfo gci = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rci,
      .stageCount = 2, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps,
      .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cbs, .pDynamicState = &ds, .layout = layout };
   VkPipeline gpipe; CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gci, NULL, &gpipe));

   /* Compute pipeline: spin.comp writes a storage buffer. */
   VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = (VkDeviceSize)groups * 64 * 4, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
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
   VkPipelineLayoutCreateInfo cplci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl,
      .pushConstantRangeCount = 1, .pPushConstantRanges = &cpr };
   VkPipelineLayout clayout; CHECK(vkCreatePipelineLayout(dev, &cplci, NULL, &clayout));
   VkShaderModuleCreateInfo smc = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(spv_spin_comp), .pCode = spv_spin_comp };
   VkShaderModule cs; CHECK(vkCreateShaderModule(dev, &smc, NULL, &cs));
   VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = cs, .pName = "main" },
      .layout = clayout };
   VkPipeline cpipe; CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &cpipe));

   /* Command buffers: barrier mode records one per frame; semaphore mode one per pass (2 per edge). */
   VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
   VkCommandPool pool; CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
   unsigned ncb = semaphore ? 2 * edges : 1;
   VkCommandBuffer cbs_[2 * MAX_EDGES];
   VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = ncb };
   CHECK(vkAllocateCommandBuffers(dev, &cai, cbs_));
   unsigned nts = 4 * edges;
   VkQueryPool qpool = VK_NULL_HANDLE;
   if (timestamps) {
      VkQueryPoolCreateInfo qpci = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = nts };
      CHECK(vkCreateQueryPool(dev, &qpci, NULL, &qpool));
   }
   VkSemaphoreTypeCreateInfo stci = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE };
   VkSemaphoreCreateInfo sci = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &stci };
   VkSemaphore tl; CHECK(vkCreateSemaphore(dev, &sci, NULL, &tl));
   uint64_t tlv = 0;
   VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
   VkFence fence; CHECK(vkCreateFence(dev, &fci, NULL, &fence));

   VkImageMemoryBarrier2 toatt = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      .srcStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, .srcAccessMask = 0,
      .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
      .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   /* render -> compute: the compute pass depends on the render's color writes (DXVK-style barrier). */
   VkMemoryBarrier2 r2c = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
      .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, .dstAccessMask = VK_ACCESS_2_SHADER_READ_BIT | VK_ACCESS_2_SHADER_WRITE_BIT };
   VkDependencyInfo r2c_di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &r2c };
   /* Barrier-shape variants (to find what makes DXVK's in-submission R->C kernel-held): source stage = color output
    * (default), fragment shader, or all graphics/commands; --event uses vkCmdSetEvent2/vkCmdWaitEvents2 (split barrier). */
   if (!strcmp(r2c_src, "fragment")) { r2c.srcStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
      r2c.srcAccessMask = VK_ACCESS_2_SHADER_WRITE_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT; }
   else if (!strcmp(r2c_src, "all")) { r2c.srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT; r2c.srcAccessMask = VK_ACCESS_2_MEMORY_WRITE_BIT;
      r2c.dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT; r2c.dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT; }
   VkEvent ev = VK_NULL_HANDLE;
   if (use_event) { VkEventCreateInfo eci = { .sType = VK_STRUCTURE_TYPE_EVENT_CREATE_INFO, .flags = VK_EVENT_CREATE_DEVICE_ONLY_BIT };
      CHECK(vkCreateEvent(dev, &eci, NULL, &ev)); }

#define REC_RENDER(cb, e, f) do { \
      VkDependencyInfo di_ = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &toatt }; \
      vkCmdPipelineBarrier2(cb, &di_); \
      if (timestamps) vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, qpool, 4 * (e) + 0); \
      VkRenderingAttachmentInfo ra_ = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view, \
         .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, \
         .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .clearValue.color.float32 = { 0, 0, 0, 1 } }; \
      VkRenderingInfo ri_ = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { width, height } }, \
         .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &ra_ }; \
      vkCmdBeginRendering(cb, &ri_); \
      vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, gpipe); \
      VkViewport vp_ = { 0, 0, (float)width, (float)height, 0, 1 }; VkRect2D sc_ = { { 0, 0 }, { width, height } }; \
      vkCmdSetViewport(cb, 0, 1, &vp_); vkCmdSetScissor(cb, 0, 1, &sc_); \
      struct pc pcv_ = { (e), 0, (f) }; \
      vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(pcv_), &pcv_); \
      vkCmdDraw(cb, 3, 1, 0, 0); \
      vkCmdEndRendering(cb); \
      if (timestamps) vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, qpool, 4 * (e) + 1); \
   } while (0)
#define REC_COMPUTE(cb, e, f) do { \
      if (timestamps) vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, qpool, 4 * (e) + 2); \
      vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, cpipe); \
      vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, clayout, 0, 1, &dset, 0, NULL); \
      uint32_t pcc_[2] = { iters, (e) ^ (f) }; \
      vkCmdPushConstants(cb, clayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, pcc_); \
      vkCmdDispatch(cb, groups, 1, 1); \
      if (timestamps) vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, qpool, 4 * (e) + 3); \
   } while (0)

   size_t cap = (size_t)frames * edges;
   double *gap_rc = calloc(cap, sizeof(double)), *gap_cr = calloc(cap, sizeof(double));
   double *rdur = calloc(cap, sizeof(double)), *cdur = calloc(cap, sizeof(double)), *ftime = calloc(frames, sizeof(double));
   size_t nrc = 0, ncr = 0, nr = 0, nc = 0, nf = 0;
   uint64_t ts[4 * MAX_EDGES];
   double t0 = now();
   for (unsigned f = 0; f < frames && now() - t0 < seconds; ++f) {
      double fs0 = now();
      if (timestamps) vkResetQueryPool(dev, qpool, 0, nts);
      VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
      if (!semaphore) {
         VkCommandBuffer cb = cbs_[0];
         CHECK(vkBeginCommandBuffer(cb, &bi));
         for (unsigned e = 0; e < edges; ++e) {
            REC_RENDER(cb, e, f);
            if (use_event) { vkCmdSetEvent2(cb, ev, &r2c_di); vkCmdWaitEvents2(cb, 1, &ev, &r2c_di);
               vkCmdResetEvent2(cb, ev, VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT); }
            else vkCmdPipelineBarrier2(cb, &r2c_di);
            REC_COMPUTE(cb, e, f);
         }
         CHECK(vkEndCommandBuffer(cb));
         VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
         CHECK(vkQueueSubmit(q, 1, &si, fence));
      } else {
         for (unsigned e = 0; e < edges; ++e) {
            VkCommandBuffer rcb = cbs_[2 * e], ccb = cbs_[2 * e + 1];
            CHECK(vkBeginCommandBuffer(rcb, &bi)); REC_RENDER(rcb, e, f); CHECK(vkEndCommandBuffer(rcb));
            CHECK(vkBeginCommandBuffer(ccb, &bi)); REC_COMPUTE(ccb, e, f); CHECK(vkEndCommandBuffer(ccb));
            /* render signals tl=v+1; compute waits on it (cross-submit render->compute edge) and signals v+2,
             * which the next edge's render waits on (compute->render). */
            uint64_t wv = tlv, sv1 = tlv + 1, sv2 = tlv + 2;
            VkPipelineStageFlags wst = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            VkTimelineSemaphoreSubmitInfo t1 = { .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
               .waitSemaphoreValueCount = tlv ? 1 : 0, .pWaitSemaphoreValues = &wv, .signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &sv1 };
            VkSubmitInfo s1 = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = &t1, .waitSemaphoreCount = tlv ? 1 : 0,
               .pWaitSemaphores = &tl, .pWaitDstStageMask = &wst, .commandBufferCount = 1, .pCommandBuffers = &rcb,
               .signalSemaphoreCount = 1, .pSignalSemaphores = &tl };
            VkTimelineSemaphoreSubmitInfo t2 = { .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
               .waitSemaphoreValueCount = 1, .pWaitSemaphoreValues = &sv1, .signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &sv2 };
            VkSubmitInfo s2 = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = &t2, .waitSemaphoreCount = 1,
               .pWaitSemaphores = &tl, .pWaitDstStageMask = &wst, .commandBufferCount = 1, .pCommandBuffers = &ccb,
               .signalSemaphoreCount = 1, .pSignalSemaphores = &tl };
            VkSubmitInfo both[2] = { s1, s2 };
            CHECK(vkQueueSubmit(q, 2, both, e + 1 == edges ? fence : VK_NULL_HANDLE));
            tlv += 2;
         }
      }
      VkResult wr = vkWaitForFences(dev, 1, &fence, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
      if (wr != VK_SUCCESS) { printf("STALL waiting frame %u result=%d t=%.3f\n", f, wr, now() - t0); return 1; }
      CHECK(vkResetFences(dev, 1, &fence));
      ftime[nf++] = (now() - fs0) * 1e6;
      if (timestamps && f >= 5 /* warm-up */) {
         CHECK(vkGetQueryPoolResults(dev, qpool, 0, nts, sizeof(ts), ts, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
         double per = props.limits.timestampPeriod / 1000.0; /* -> us */
         for (unsigned e = 0; e < edges; ++e) {
            rdur[nr++] = (double)(ts[4 * e + 1] - ts[4 * e + 0]) * per;
            cdur[nc++] = (double)(ts[4 * e + 3] - ts[4 * e + 2]) * per;
            gap_rc[nrc++] = ((double)ts[4 * e + 2] - (double)ts[4 * e + 1]) * per;
            if (e + 1 < edges) gap_cr[ncr++] = ((double)ts[4 * (e + 1)] - (double)ts[4 * e + 3]) * per;
         }
      }
   }
   double el = now() - t0;
   printf("frames=%zu in %.2f s: %.1f frames/s, %.1f edges/s\n", nf, el, nf / el, nf * edges / el);
   stats("cpu frame time", ftime, nf);
   if (timestamps) {
      stats("render pass (ts)", rdur, nr);
      stats("compute pass (ts)", cdur, nc);
      stats("render-end -> compute-start gap (ts)", gap_rc, nrc);
      stats("compute-end -> next render-start gap (ts)", gap_cr, ncr);
   }
   printf("PASS\n");
   return 0;
}
