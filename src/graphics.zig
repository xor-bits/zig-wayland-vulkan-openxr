// https://github.com/andrewrk/zig-vulkan-triangle
// https://github.com/Snektron/vulkan-zig

const wl = @import("wayland");

const std = @import("std");

const vk = @import("vulkan");

//

const gpa = std.heap.c_allocator;

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    // vk.features.version_1_1,
    // vk.features.version_1_2,
    // vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.khr_wayland_surface,
    vk.extensions.ext_debug_utils,
};

const device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

//

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);
const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);
const CommandBuffer = vk.CommandBufferProxy(apis);
const Queue = vk.QueueProxy(apis);

const vkGetInstanceProcAddr = @extern(vk.PfnGetInstanceProcAddr, .{
    .name = "vkGetInstanceProcAddr",
    .library_name = "vulkan",
});

//

pub fn init(wl_display: *wl.server.wl.Server, wl_surface: *wl.server.wl.Surface) anyerror!void {
    var extension_names_buffer: [3][*:0]const u8 = undefined;
    var extension_names: std.ArrayListUnmanaged([*:0]const u8) = .{
        .items = extension_names_buffer[0..0],
        .capacity = extension_names_buffer.len,
    };
    extension_names.appendAssumeCapacity("VK_KHR_surface");
    extension_names.appendAssumeCapacity("VK_KHR_wayland_surface");
    extension_names.appendAssumeCapacity("VK_EXT_debug_utils");

    var layer_names_buffer: [3][*:0]const u8 = undefined;
    var layer_names: std.ArrayListUnmanaged([*:0]const u8) = .{
        .items = layer_names_buffer[0..0],
        .capacity = layer_names_buffer.len,
    };
    layer_names.appendAssumeCapacity("VK_LAYER_KHRONOS_validation");

    const vkb = try BaseDispatch.load(vkGetInstanceProcAddr);
    const layers = try vkb.enumerateInstanceLayerPropertiesAlloc(gpa);
    for (layers) |layer| {
        const layer_name = std.mem.sliceTo(&layer.layer_name, 0);
        std.log.info("layer: {s}", .{layer_name});
    }

    std.log.scoped(.vk_init).info("creating instance", .{});
    const instance_handle = try vkb.createInstance(&vk.InstanceCreateInfo{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = "zig-wayland-vulkan-openxr",
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        },
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,
        .enabled_layer_count = @intCast(layer_names.items.len),
        .pp_enabled_layer_names = layer_names.items.ptr,
    }, null);

    const vki = try gpa.create(InstanceDispatch);
    errdefer gpa.destroy(vki);
    vki.* = try InstanceDispatch.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr);
    const instance = Instance.init(instance_handle, vki);
    errdefer instance.destroyInstance(null);

    std.log.scoped(.vk_init).info("creating debug messenger", .{});
    const debug_messenger = try instance.createDebugUtilsMessengerEXT(&.{
        .message_severity = .{
            .error_bit_ext = true,
            .warning_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
            .device_address_binding_bit_ext = true,
        },
        .pfn_user_callback = debugCallback,
    }, null);
    _ = debug_messenger;

    std.log.scoped(.vk_init).info("creating vk surface", .{});
    const surface = try instance.createWaylandSurfaceKHR(&.{
        .display = @ptrCast(wl_display),
        .surface = @ptrCast(wl_surface),
    }, null);

    std.log.scoped(.vk_init).info("testing physical devices", .{});
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);

    std.log.scoped(.vk_init).info("ranking {d} physical devices", .{pdevs.len});
    var pdev_candidates = try std.ArrayList(PhysicalDeviceCandidate).initCapacity(
        gpa,
        pdevs.len,
    );
    defer pdev_candidates.deinit();

    std.log.scoped(.vk_init).info("a", .{});
    for (pdevs) |pdev| {
        std.log.scoped(.vk_init).info("b", .{});
        if (try isSuitable(instance, pdev, surface)) |pdev_candidate| {
            std.log.scoped(.vk_init).info("c", .{});
            try pdev_candidates.append(pdev_candidate);
        }
    }

    if (pdev_candidates.items.len == 0) {
        std.log.scoped(.vk_init).err("no suitable GPUs", .{});
    }

    std.log.scoped(.vk_init).info("found {d} suitable GPUs", .{pdev_candidates.items.len});
    std.sort.pdq(PhysicalDeviceCandidate, pdev_candidates.items, {}, PhysicalDeviceCandidate.asc);
}

fn debugCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = severity;
    _ = types;
    _ = user_data;
    const msg = b: {
        break :b (data orelse break :b "<no data>").p_message orelse "<no message>";
    };

    std.log.scoped(.validation).warn("{s}", .{msg});

    return vk.FALSE;
}

const PhysicalDeviceCandidate = struct {
    memory: u64,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    fn devTypeToInt(dev_type: vk.PhysicalDeviceType) i32 {
        switch (dev_type) {
            .other => return 0,
            .integrated_gpu => return 1,
            .discrete_gpu => return 2,
            .virtual_gpu => return 3,
            .cpu => return 4,
            _ => return 0,
        }
    }

    fn asc(_: void, a: PhysicalDeviceCandidate, b: PhysicalDeviceCandidate) bool {
        const dev_type_cmp = devTypeToInt(b.props.device_type) - devTypeToInt(a.props.device_type);
        if (dev_type_cmp > 0) {
            return true;
        } else if (dev_type_cmp < 0) {
            return true;
        } else {
            if (a.memory < b.memory) {
                return true;
            } else {
                return false;
            }
        }
    }
};

fn isSuitable(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !?PhysicalDeviceCandidate {
    std.log.scoped(.vk_init).info("checkSurfaceSupport", .{});
    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    std.log.scoped(.vk_init).info("checkExtensionSupport", .{});
    if (!try checkExtensionSupport(instance, pdev)) {
        return null;
    }

    const props = instance.getPhysicalDeviceProperties(pdev);
    const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

    std.log.info("suitable gpu: {s}", .{std.mem.sliceTo(&props.device_name, 0)});

    var total_memory: u64 = 0;
    for (mem_props.memory_heaps) |heap| {
        if (heap.flags.device_local_bit)
            total_memory += heap.size;
    }

    return PhysicalDeviceCandidate{
        .memory = total_memory,
        .props = props,
        .mem_props = mem_props,
    };
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);
    if (format_count == 0) return false;

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);
    if (present_mode_count == 0) return false;

    return true;
}

fn checkExtensionSupport(instance: Instance, pdev: vk.PhysicalDevice) !bool {
    const props = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, gpa);
    defer gpa.free(props);

    for (device_extensions) |ext| {
        // test if the phys device has this `ext`

        for (props) |avail_ext| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&avail_ext.extension_name, 0))) {
                break;
            }
        } else {
            // ext not avail
            return false;
        }
    }

    return true;
}
