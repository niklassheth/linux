/* SPDX-License-Identifier: GPL-2.0-only */
/* Own Vulkan workload: isolate loader/layer/device/mapped-memory setup.
 * No shader or queue submission. Intended for x86 FEX and native AArch64. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CALL(expression) do { \
   printf("before: %s\n", #expression); \
   VkResult result = (expression); \
   printf("after: %s = %d\n", #expression, result); \
   if (result != VK_SUCCESS) return 2; \
} while (0)

static void mappings(const char *stage)
{
   const char *path = getenv("G16_PROBE_MAPS");
   if (!path) return;
   FILE *source = fopen("/proc/self/maps", "r");
   FILE *output = fopen(path, "a");
   if (!source || !output) {
      if (source) fclose(source);
      if (output) fclose(output);
      return;
   }
   fprintf(output, "stage=%s\n", stage);
   char line[4096];
   while (fgets(line, sizeof(line), source))
      if (strstr(line, "libvulkan") || strstr(line, "libVkLayer") || strstr(line, "FEX"))
         fputs(line, output);
   fclose(output);
   fclose(source);
}

int main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   const char *mode = argc > 1 ? argv[1] : "baseline";
   if (strcmp(mode, "baseline") && strcmp(mode, "unassisted") && strcmp(mode, "page_guard"))
      return 64;
   const char *layer = "VK_LAYER_LUNARG_gfxreconstruct";
   const char *variables[] = {"VK_INSTANCE_LAYERS", "VK_LAYER_PATH", "VK_DRIVER_FILES",
      "GFXRECON_MEMORY_TRACKING_MODE", "GFXRECON_CAPTURE_FILE", "GFXRECON_LOG_FILE"};
   printf("probe mode=%s pointer_bits=%zu\n", mode, sizeof(void *) * 8);
   for (unsigned i = 0; i < sizeof(variables) / sizeof(variables[0]); ++i) {
      const char *value = getenv(variables[i]);
      printf("environment %s=%s\n", variables[i], value ? value : "<unset>");
   }
   VkApplicationInfo application = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "g16-capture-probe", .apiVersion = VK_API_VERSION_1_2,
   };
   VkInstanceCreateInfo instance_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &application,
      .enabledLayerCount = strcmp(mode, "baseline") ? 1 : 0,
      .ppEnabledLayerNames = &layer,
   };
   VkInstance instance;
   CALL(vkCreateInstance(&instance_info, NULL, &instance));
   mappings("instance");
   uint32_t count = 0;
   CALL(vkEnumeratePhysicalDevices(instance, &count, NULL));
   if (!count) return 2;
   VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
   if (!devices) return 2;
   CALL(vkEnumeratePhysicalDevices(instance, &count, devices));
   VkPhysicalDevice physical = devices[0];
   free(devices);
   VkPhysicalDeviceDriverProperties driver = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
   };
   VkPhysicalDeviceProperties2 properties = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &driver,
   };
   puts("before: vkGetPhysicalDeviceProperties2");
   vkGetPhysicalDeviceProperties2(physical, &properties);
   printf("device=%s driver=%s version=%s\n", properties.properties.deviceName,
          driver.driverName, driver.driverInfo);
   vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, NULL);
   VkQueueFamilyProperties *families = calloc(count, sizeof(*families));
   if (!families) return 2;
   vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
   uint32_t family = count;
   for (uint32_t i = 0; i < count; ++i)
      if (families[i].queueCount && (families[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) {
         family = i;
         break;
      }
   free(families);
   if (family == count) return 2;
   float priority = 1.0f;
   VkDeviceQueueCreateInfo queue_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority,
   };
   VkDeviceCreateInfo device_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info,
   };
   VkDevice device;
   CALL(vkCreateDevice(physical, &device_info, NULL, &device));
   mappings("device");
   VkBufferCreateInfo buffer_info = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 65536,
      .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   VkBuffer buffer;
   CALL(vkCreateBuffer(device, &buffer_info, NULL, &buffer));
   VkMemoryRequirements requirements;
   vkGetBufferMemoryRequirements(device, buffer, &requirements);
   VkPhysicalDeviceMemoryProperties memory_properties;
   vkGetPhysicalDeviceMemoryProperties(physical, &memory_properties);
   uint32_t memory_type = memory_properties.memoryTypeCount;
   for (uint32_t i = 0; i < memory_properties.memoryTypeCount; ++i)
      if ((requirements.memoryTypeBits & (1u << i)) &&
          (memory_properties.memoryTypes[i].propertyFlags &
           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
         memory_type = i;
         break;
      }
   if (memory_type == memory_properties.memoryTypeCount) return 2;
   VkMemoryAllocateInfo allocation = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = requirements.size, .memoryTypeIndex = memory_type,
   };
   VkDeviceMemory memory;
   CALL(vkAllocateMemory(device, &allocation, NULL, &memory));
   CALL(vkBindBufferMemory(device, buffer, memory, 0));
   void *mapping;
   CALL(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapping));
   puts("before: mapped memory write");
   memset(mapping, 0x5a, (size_t)requirements.size);
   puts("after: mapped memory write");
   VkMappedMemoryRange range = {
      .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
      .memory = memory, .size = VK_WHOLE_SIZE,
   };
   CALL(vkFlushMappedMemoryRanges(device, 1, &range));
   vkUnmapMemory(device, memory);
   puts("before: teardown");
   vkDestroyBuffer(device, buffer, NULL);
   vkFreeMemory(device, memory, NULL);
   vkDestroyDevice(device, NULL);
   vkDestroyInstance(instance, NULL);
   puts("probe completed; no GPU work submitted");
   return 0;
}
