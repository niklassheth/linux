// SPDX-License-Identifier: MIT
/* render_present: models Dota's A4 stall submission. Each frame acquires an
 * XCB swapchain image (B8G8R8A8_SRGB, 1280x720 by default, uncompressed as
 * hk's WSI images are), optionally renders --offscreen small passes into a
 * compressed RGBA8 image, then renders --passes (default 3) single-draw
 * passes into the swapchain image with LOAD/STORE, src-alpha blending and an
 * RGB-only write mask, and presents. --inflight frames are pipelined; every
 * fence wait has a timeout that reports STALL.
 *
 *   render_present [--passes N] [--offscreen M] [--width W --height H]
 *                  [--inflight K] [--mode fifo|mailbox|immediate]
 *                  [--seconds S] [--timeout-ms T] [--work R] [--warmup-small N]
 * --resize-ms M: every M ms toggle the X window between WxH and --resize-w x --resize-h
 *   (default 1920x1080) through Xwayland/the compositor, like KWin growing Dota's borderless
 *   window; offscreen WxH passes continue. --recreate: rebuild the swapchain at the surface's
 *   current extent after SUBOPTIMAL (OUT_OF_DATE always rebuilds).
 * --swap-w/--swap-h: swapchain extent independent of the window (Dota: 1920x1080 swapchain,
 *   1280x720 window). --burst-resize-ms D: right before the first non-warmup frame, resize the
 *   window to --resize-w x --resize-h and wait D ms, then render the burst frame (offscreen WxH
 *   LOAD passes + the first-ever swapchain-size passes), like Dota's loading-end burst.
 * --win-w/--win-h: initial window size (default WxH); e.g. a 1920x1080 window on a 1920x1080
 *   swapchain presents by FLIP, and --burst-resize-ms with --resize-w 1280 --resize-h 720 then
 *   switches Xwayland to COPY right before the burst (Dota's FLIP->COPY sequence).
 * --split-burst: on burst frames submit each offscreen WxH pass (CLEAR, then LOADs, into a
 *   freshly discarded intermediate) as its own vkQueueSubmit, ~tens of us apart, like Dota's
 *   loading-end burst. --burst-every N: after warmup, only every Nth frame is a burst frame; the
 *   others are small-only like warmup frames (many bursts per process).
 * --warmup-small N: for the first N frames render only small offscreen passes
 * (112x170 .. 298x452, as Dota's early frames) and present the swapchain image
 * untouched; the first swapchain LOAD pass then comes on frame N, in a context
 * that has only seen small renders (Dota's A4 ordering).
 */
#include <xcb/xcb.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_xcb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include "spirv.h"

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
   fprintf(stderr, "%s:%d %s = %d\n", __FILE__, __LINE__, #x, r_); exit(2); } } while (0)

struct pc { uint32_t draw, work, frame; };

static double now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec + t.tv_nsec * 1e-9;
}

static VkDevice dev;
static VkPhysicalDeviceMemoryProperties mp;

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
   for (uint32_t t = 0; t < mp.memoryTypeCount; ++t)
      if ((bits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want)
         return t;
   fprintf(stderr, "no memory type\n");
   exit(2);
}

static VkPipeline make_pipeline(VkPipelineLayout layout, VkShaderModule vs, VkShaderModule fs,
                                VkFormat format, uint32_t write_mask)
{
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
   VkPipelineColorBlendAttachmentState att = { .blendEnable = VK_TRUE,
      .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA, .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
      .colorBlendOp = VK_BLEND_OP_ADD, .srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
      .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = VK_BLEND_OP_ADD,
      .colorWriteMask = write_mask };
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
   VkPipeline p; CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gci, NULL, &p));
   return p;
}

static void pass(VkCommandBuffer cb, VkImageView view, VkAttachmentLoadOp load, uint32_t w, uint32_t h,
                 VkPipeline pipe, VkPipelineLayout layout, struct pc pcv)
{
   VkRenderingAttachmentInfo ra = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
      .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .loadOp = load, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      .clearValue.color.float32 = { 0.05f, 0.1f, 0.15f, 1 } };
   VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
      .renderArea = { { 0, 0 }, { w, h } }, .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &ra };
   vkCmdBeginRendering(cb, &ri);
   vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
   VkViewport vpt = { 0, 0, (float)w, (float)h, 0, 1 };
   VkRect2D sc = { { 0, 0 }, { w, h } };
   vkCmdSetViewport(cb, 0, 1, &vpt); vkCmdSetScissor(cb, 0, 1, &sc);
   vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(pcv), &pcv);
   vkCmdDraw(cb, 3, 1, 0, 0);
   vkCmdEndRendering(cb);
}

static void barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to,
                    VkPipelineStageFlags2 src, VkAccessFlags2 srca, VkPipelineStageFlags2 dst, VkAccessFlags2 dsta)
{
   VkImageMemoryBarrier2 b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
      .srcStageMask = src, .srcAccessMask = srca, .dstStageMask = dst, .dstAccessMask = dsta,
      .oldLayout = from, .newLayout = to,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b };
   vkCmdPipelineBarrier2(cb, &di);
}

int main(int argc, char **argv)
{
   unsigned passes = 3, offscreen = 4, width = 1280, height = 720, inflight = 2;
   unsigned seconds = 60, timeout_ms = 5000, work = 0, warmup = 0;
   unsigned resize_ms = 0, resize_w = 1920, resize_h = 1080;
   bool recreate = false;
   unsigned swap_w = 0, swap_h = 0;
   int burst_resize_ms = -1;
   unsigned win_w = 0, win_h = 0;
   bool split_burst = false;
   unsigned burst_every = 0, bursts = 0;
   VkPresentModeKHR mode = VK_PRESENT_MODE_FIFO_KHR;
   for (int i = 1; i < argc; ++i) {
      if (!strcmp(argv[i], "--passes") && i + 1 < argc) passes = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--offscreen") && i + 1 < argc) offscreen = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--width") && i + 1 < argc) width = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--height") && i + 1 < argc) height = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--inflight") && i + 1 < argc) inflight = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--work") && i + 1 < argc) work = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--warmup-small") && i + 1 < argc) warmup = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--resize-ms") && i + 1 < argc) resize_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--resize-w") && i + 1 < argc) resize_w = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--resize-h") && i + 1 < argc) resize_h = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--recreate")) recreate = true;
      else if (!strcmp(argv[i], "--swap-w") && i + 1 < argc) swap_w = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--win-w") && i + 1 < argc) win_w = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--split-burst")) split_burst = true;
      else if (!strcmp(argv[i], "--burst-every") && i + 1 < argc) burst_every = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--win-h") && i + 1 < argc) win_h = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--swap-h") && i + 1 < argc) swap_h = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--burst-resize-ms") && i + 1 < argc) burst_resize_ms = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
         const char *m = argv[++i];
         mode = !strcmp(m, "mailbox") ? VK_PRESENT_MODE_MAILBOX_KHR :
                !strcmp(m, "immediate") ? VK_PRESENT_MODE_IMMEDIATE_KHR : VK_PRESENT_MODE_FIFO_KHR;
      } else { fprintf(stderr, "bad arg %s\n", argv[i]); return 64; }
   }
   if (inflight < 1) inflight = 1;
   if (inflight > 8) inflight = 8;

   /* Window. */
   int screen_num;
   xcb_connection_t *conn = xcb_connect(NULL, &screen_num);
   if (!conn || xcb_connection_has_error(conn)) { fprintf(stderr, "no X connection\n"); return 2; }
   xcb_screen_iterator_t it = xcb_setup_roots_iterator(xcb_get_setup(conn));
   for (int s = 0; s < screen_num; ++s) xcb_screen_next(&it);
   xcb_window_t win = xcb_generate_id(conn);
   xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, it.data->root, 0, 0, win_w ? win_w : width, win_h ? win_h : height, 0,
                     XCB_WINDOW_CLASS_INPUT_OUTPUT, it.data->root_visual, 0, NULL);
   xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8, 14, "render_present");
   xcb_map_window(conn, win);
   xcb_flush(conn);

   const char *iext[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XCB_SURFACE_EXTENSION_NAME };
   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "render_present", .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
      .enabledExtensionCount = 2, .ppEnabledExtensionNames = iext };
   VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
   VkXcbSurfaceCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR, .connection = conn, .window = win };
   VkSurfaceKHR surf; CHECK(vkCreateXcbSurfaceKHR(inst, &sci, NULL, &surf));
   uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
   if (!n) { fprintf(stderr, "no device\n"); return 2; }
   VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
   printf("device %s driver 0x%x\n", props.deviceName, props.driverVersion);
   VkBool32 ok = VK_FALSE; vkGetPhysicalDeviceSurfaceSupportKHR(pd, 0, surf, &ok);
   if (!ok) { fprintf(stderr, "queue 0 cannot present\n"); return 2; }
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   float prio = 1;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .synchronization2 = VK_TRUE, .dynamicRendering = VK_TRUE };
   const char *dext[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
      .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

   /* Swapchain: prefer B8G8R8A8_SRGB like Dota. */
   uint32_t nf = 0; vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, NULL);
   VkSurfaceFormatKHR *fmts = calloc(nf, sizeof(*fmts)); vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, fmts);
   VkSurfaceFormatKHR sf = fmts[0];
   for (uint32_t i = 0; i < nf; ++i) if (fmts[i].format == VK_FORMAT_B8G8R8A8_SRGB) sf = fmts[i];
   VkSurfaceCapabilitiesKHR caps; vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surf, &caps);
   uint32_t nimg = caps.minImageCount + 1;
   if (caps.maxImageCount && nimg > caps.maxImageCount) nimg = caps.maxImageCount;
   uint32_t nm = 0; vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surf, &nm, NULL);
   VkPresentModeKHR pms[8]; if (nm > 8) nm = 8; vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surf, &nm, pms);
   bool have = false; for (uint32_t i = 0; i < nm; ++i) have |= pms[i] == mode;
   if (!have) mode = VK_PRESENT_MODE_FIFO_KHR;
   VkSwapchainCreateInfoKHR swci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surf,
      .minImageCount = nimg, .imageFormat = sf.format, .imageColorSpace = sf.colorSpace,
      .imageExtent = { width, height }, .imageArrayLayers = 1,
      .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
      .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform,
      .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = mode, .clipped = VK_TRUE };
   VkSwapchainKHR swc = VK_NULL_HANDLE;
   uint32_t sn = 0, sw_w = swap_w ? swap_w : width, sw_h = swap_h ? swap_h : height;
   VkImage simg[16]; VkImageView sview[16]; bool first_use[16]; VkSemaphore done[16];
   VkSemaphoreCreateInfo semci = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
   unsigned recreates = 0;
#define BUILD_SWAPCHAIN() do { \
      VkSwapchainKHR old = swc; \
      if (old) { \
         vkQueueWaitIdle(q); \
         for (uint32_t i = 0; i < sn; ++i) { vkDestroyImageView(dev, sview[i], NULL); vkDestroySemaphore(dev, done[i], NULL); } \
         vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surf, &caps); \
         if (caps.currentExtent.width != 0xffffffffu && caps.currentExtent.width) { sw_w = caps.currentExtent.width; sw_h = caps.currentExtent.height; } \
      } \
      swci.imageExtent = (VkExtent2D){ sw_w, sw_h }; swci.oldSwapchain = old; \
      CHECK(vkCreateSwapchainKHR(dev, &swci, NULL, &swc)); \
      if (old) vkDestroySwapchainKHR(dev, old, NULL); \
      sn = 0; vkGetSwapchainImagesKHR(dev, swc, &sn, NULL); \
      if (sn > 16) sn = 16; \
      vkGetSwapchainImagesKHR(dev, swc, &sn, simg); \
      for (uint32_t i = 0; i < sn; ++i) { \
         VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = simg[i], \
            .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = sf.format, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } }; \
         CHECK(vkCreateImageView(dev, &vci, NULL, &sview[i])); \
         CHECK(vkCreateSemaphore(dev, &semci, NULL, &done[i])); \
         first_use[i] = true; \
      } \
   } while (0)
   BUILD_SWAPCHAIN();

   /* Offscreen compressed RGBA8 target. */
   VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { width, height, 1 }, .mipLevels = 1, .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT };
   VkImage off; CHECK(vkCreateImage(dev, &ii, NULL, &off));
   VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, off, &mr);
   VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
      .memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
   VkDeviceMemory offmem; CHECK(vkAllocateMemory(dev, &mai, NULL, &offmem)); CHECK(vkBindImageMemory(dev, off, offmem, 0));
   VkImageViewCreateInfo ovci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = off,
      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   VkImageView offview; CHECK(vkCreateImageView(dev, &ovci, NULL, &offview));

   /* Small offscreen target for --warmup-small (largest of Dota's early sizes). */
   const unsigned small_w[4] = { 112, 224, 246, 298 }, small_h[4] = { 170, 339, 372, 452 };
   VkImageCreateInfo sii = ii; sii.extent = (VkExtent3D){ 298, 452, 1 };
   VkImage smallimg; CHECK(vkCreateImage(dev, &sii, NULL, &smallimg));
   VkMemoryRequirements smr; vkGetImageMemoryRequirements(dev, smallimg, &smr);
   VkMemoryAllocateInfo smai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = smr.size,
      .memoryTypeIndex = mem_type(smr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
   VkDeviceMemory smallmem; CHECK(vkAllocateMemory(dev, &smai, NULL, &smallmem)); CHECK(vkBindImageMemory(dev, smallimg, smallmem, 0));
   VkImageViewCreateInfo svci = ovci; svci.image = smallimg;
   VkImageView smallview; CHECK(vkCreateImageView(dev, &svci, NULL, &smallview));
   bool small_first = true;

   VkShaderModuleCreateInfo smv = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(spv_fs_vert), .pCode = spv_fs_vert };
   VkShaderModuleCreateInfo smf = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(spv_a_frag), .pCode = spv_a_frag };
   VkShaderModule vs, fs; CHECK(vkCreateShaderModule(dev, &smv, NULL, &vs)); CHECK(vkCreateShaderModule(dev, &smf, NULL, &fs));
   VkPushConstantRange pcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(struct pc) };
   VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
   VkPipelineLayout layout; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
   VkPipeline pipe_sw = make_pipeline(layout, vs, fs, sf.format, 7 /* RGB, as Dota's pass */);
   VkPipeline pipe_off = make_pipeline(layout, vs, fs, VK_FORMAT_R8G8B8A8_UNORM, 0xf);

   VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
   VkCommandPool pool; CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
   VkCommandBuffer cbs[8];
   VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = inflight };
   CHECK(vkAllocateCommandBuffers(dev, &cai, cbs));
   VkCommandBuffer bcbs[8];
   VkCommandBufferAllocateInfo bcai = cai; bcai.commandBufferCount = 8;
   CHECK(vkAllocateCommandBuffers(dev, &bcai, bcbs));
   VkFence fences[8]; VkSemaphore acq[8];
   VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
   for (unsigned f = 0; f < inflight; ++f) { CHECK(vkCreateFence(dev, &fci, NULL, &fences[f])); CHECK(vkCreateSemaphore(dev, &semci, NULL, &acq[f])); }

   printf("swapchain format=%d images=%u mode=%d passes=%u offscreen=%u size=%ux%u inflight=%u seconds=%u\n",
          sf.format, sn, mode, passes, offscreen, width, height, inflight, seconds);
   fflush(stdout);
   double t0 = now(), last = t0;
   bool off_first = true;
   unsigned long frames = 0;
   double next_resize = t0 + resize_ms / 1000.0;
   bool big = false;
   unsigned resizes = 0, suboptimal = 0;
   bool need_recreate = false;
   for (unsigned k = 0; now() - t0 < seconds; ++k) {
      unsigned slot = k % inflight;
      if (resize_ms && now() >= next_resize) {
         big = !big;
         uint32_t wh[2] = { big ? resize_w : width, big ? resize_h : height };
         xcb_configure_window(conn, win, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, wh);
         xcb_flush(conn);
         resizes++;
         next_resize = now() + resize_ms / 1000.0;
      }
      if (need_recreate) {
         BUILD_SWAPCHAIN();
         recreates++;
         need_recreate = false;
      }
      VkResult wr = vkWaitForFences(dev, 1, &fences[slot], VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
      if (wr != VK_SUCCESS) {
         printf("STALL waiting frame %u (slot %u) result=%d t=%.3f frames=%lu\n", k, slot, wr, now() - t0, frames);
         fflush(stdout);
         return 1;
      }
      uint32_t idx;
      VkResult ar = vkAcquireNextImageKHR(dev, swc, (uint64_t)timeout_ms * 1000000ull, acq[slot], VK_NULL_HANDLE, &idx);
      if (ar == VK_TIMEOUT || ar == VK_NOT_READY) { printf("STALL acquire result=%d t=%.3f frames=%lu\n", ar, now() - t0, frames); fflush(stdout); return 1; }
      if (ar == VK_ERROR_OUT_OF_DATE_KHR) { need_recreate = true; --k; continue; }
      if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) { fprintf(stderr, "acquire %d\n", ar); return 2; }
      if (ar == VK_SUBOPTIMAL_KHR) { suboptimal++; if (recreate) need_recreate = true; }
      CHECK(vkResetFences(dev, 1, &fences[slot]));
      VkCommandBuffer cb = cbs[slot];
      VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
      CHECK(vkBeginCommandBuffer(cb, &bi));
      bool burst_frame = k >= warmup && (!burst_every || (k - warmup) % burst_every == 0);
      if (!burst_frame) {
         /* Dota-like early frames: only small offscreen passes; swapchain image untouched. */
         for (unsigned p = 0; p < 4; ++p) {
            barrier(cb, smallimg, small_first ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
            small_first = false;
            pass(cb, smallview, p == 0 ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD, small_w[p], small_h[p], pipe_off, layout, (struct pc){ p, work, k });
         }
         barrier(cb, simg[idx], first_use[idx] ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                 VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, 0, VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, 0);
         first_use[idx] = false;
         goto submit;
      }
      if (k == warmup && warmup && burst_resize_ms >= 0) {
         uint32_t wh[2] = { resize_w, resize_h };
         xcb_configure_window(conn, win, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, wh);
         xcb_flush(conn);
         struct timespec ts = { burst_resize_ms / 1000, (burst_resize_ms % 1000) * 1000000L };
         nanosleep(&ts, NULL);
      }
      if (k == warmup && warmup) { printf("first swapchain pass at frame %u t=%.3f (%ux%u)\n", k, now() - t0, sw_w, sw_h); fflush(stdout); }
      if (split_burst) {
         /* Separate submits per pass; the previous burst's passes are done (fence wait above
          * covers this slot only, so drain the queue's earlier burst submits first). */
         CHECK(vkQueueWaitIdle(q));
         off_first = true;
         for (unsigned p = 0; p < offscreen && p < 8; ++p) {
            VkCommandBuffer bcb = bcbs[p];
            CHECK(vkResetCommandBuffer(bcb, 0));
            CHECK(vkBeginCommandBuffer(bcb, &bi));
            barrier(bcb, off, off_first ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
            off_first = false;
            pass(bcb, offview, p == 0 ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD, width, height, pipe_off, layout, (struct pc){ p, work, k });
            CHECK(vkEndCommandBuffer(bcb));
            VkSubmitInfo bsi = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &bcb };
            CHECK(vkQueueSubmit(q, 1, &bsi, VK_NULL_HANDLE));
         }
         bursts++;
      }
      for (unsigned p = 0; p < (split_burst ? 0 : offscreen); ++p) {
         barrier(cb, off, off_first ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                 VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                 VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
         off_first = false;
         pass(cb, offview, p == 0 ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD, width, height, pipe_off, layout, (struct pc){ p, work, k });
      }
      /* Swapchain chain: LOAD (contents preserved), blend, RGB mask. */
      barrier(cb, simg[idx], first_use[idx] ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
              VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
              VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
      first_use[idx] = false;
      for (unsigned p = 0; p < passes; ++p) {
         if (p)
            barrier(cb, simg[idx], VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
         pass(cb, sview[idx], VK_ATTACHMENT_LOAD_OP_LOAD, sw_w, sw_h, pipe_sw, layout, (struct pc){ 100 + p, work, k });
      }
      barrier(cb, simg[idx], VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
              VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
              VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, 0);
   submit:
      CHECK(vkEndCommandBuffer(cb));
      VkPipelineStageFlags ws = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
      VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acq[slot],
         .pWaitDstStageMask = &ws, .commandBufferCount = 1, .pCommandBuffers = &cb,
         .signalSemaphoreCount = 1, .pSignalSemaphores = &done[idx] };
      CHECK(vkQueueSubmit(q, 1, &si, fences[slot]));
      VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &done[idx],
         .swapchainCount = 1, .pSwapchains = &swc, .pImageIndices = &idx };
      VkResult pr = vkQueuePresentKHR(q, &pi);
      if (pr == VK_ERROR_OUT_OF_DATE_KHR) need_recreate = true;
      else if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR) { fprintf(stderr, "present %d t=%.3f\n", pr, now() - t0); return 2; }
      else if (pr == VK_SUBOPTIMAL_KHR && recreate) need_recreate = true;
      frames++;
      if (now() - last > 5) { last = now(); printf("t=%.1f frames=%lu (%.0f fps) resizes=%u suboptimal=%u recreates=%u\n", last - t0, frames, frames / (last - t0), resizes, suboptimal, recreates); fflush(stdout); }
   }
   VkResult fr = vkWaitForFences(dev, inflight, fences, VK_TRUE, (uint64_t)timeout_ms * 1000000ull);
   if (fr != VK_SUCCESS) { printf("STALL draining result=%d\n", fr); return 1; }
   printf("PASS frames=%lu in %.1f s resizes=%u suboptimal=%u recreates=%u bursts=%u\n", frames, now() - t0, resizes, suboptimal, recreates, bursts);
   return 0;
}
