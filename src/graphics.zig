// https://github.com/andrewrk/zig-vulkan-triangle
// https://github.com/Snektron/vulkan-zig

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const vk = @import("vulkan");

//

const gpa = std.heap.c_allocator;

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    // vk.features.version_1_2,
    // vk.features.version_1_3,
    vk.extensions.ext_physical_device_drm,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.khr_wayland_surface,
    vk.extensions.ext_debug_utils,
};

const phys_device_extensions = [_][]const u8{
    vk.extensions.ext_physical_device_drm.name,
    // vk.extensions.khr_driver_properties.name,
    // vk.extensions.ext_external_memory_dma_buf.name,
    vk.extensions.khr_swapchain.name,
};

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

pub const CustomRenderer = struct {
    vkb: BaseDispatch,
    vki: InstanceDispatch,

    instance: Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    pdev: vk.PhysicalDevice,

    graphics_queue_family: u32,

    sync_file_import_export: bool,
    implicit_sync_interop: bool,

    sampler_ycbcr_conversion: bool,

    device: vk.Device,

    const Self = @This();

    pub fn autocreate(backend: *wlr.Backend) !*wlr.Renderer {
        const drm_fd = try preferredDrmFd(backend);

        std.log.info("preferred drm fd: {any}", .{drm_fd});

        // allocate the renderer
        var renderer = try gpa.create(Self);
        errdefer gpa.destroy(renderer);

        // dynamic load vulkan
        renderer.vkb = try BaseDispatch.load(vkGetInstanceProcAddr);

        try createInstance(renderer);
        errdefer renderer.instance.destroyInstance(null);

        try createDebugMessenger(renderer);
        errdefer renderer.instance.destroyDebugUtilsMessengerEXT(renderer.debug_messenger, null);

        try createPdev(renderer, drm_fd.fd);

        try createDevice(renderer);

        return error.Success;
    }

    const PreferredDrmFd = struct {
        fd: i32,
        owned: bool,
    };

    fn preferredDrmFd(backend: *wlr.Backend) !PreferredDrmFd {
        const backend_drm_fd = backend.getDrmFd();
        if (backend_drm_fd >= 0) {
            return .{
                .fd = backend_drm_fd,
                .owned = false,
            };
        }

        // TODO: pick arbitary render node

        return error.NoDrmFdAvailable;
    }

    fn createInstance(self: *Self) !void {
        var extension_names_buffer: [3][*:0]const u8 = undefined;
        var extension_names: std.ArrayListUnmanaged([*:0]const u8) = .{
            .items = extension_names_buffer[0..0],
            .capacity = extension_names_buffer.len,
        };
        extension_names.appendAssumeCapacity(vk.extensions.khr_surface.name);
        extension_names.appendAssumeCapacity(vk.extensions.khr_wayland_surface.name);
        extension_names.appendAssumeCapacity(vk.extensions.ext_debug_utils.name);

        var layer_names_buffer: [3][*:0]const u8 = undefined;
        var layer_names: std.ArrayListUnmanaged([*:0]const u8) = .{
            .items = layer_names_buffer[0..0],
            .capacity = layer_names_buffer.len,
        };
        layer_names.appendAssumeCapacity("VK_LAYER_KHRONOS_validation");

        std.log.scoped(.vk_init).info("creating instance", .{});
        const instance_handle = try self.vkb.createInstance(&vk.InstanceCreateInfo{
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

        self.vki = try InstanceDispatch.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = Instance.init(instance_handle, &self.vki);
    }

    fn createDebugMessenger(self: *Self) !void {
        std.log.scoped(.vk_init).info("creating debug messenger", .{});
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
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
    }

    fn createPdev(self: *Self, drm_fd: i32) !void {
        std.log.scoped(.vk_init).info("picking a GPU", .{});

        const pdevs = try self.instance.enumeratePhysicalDevicesAlloc(gpa);
        defer gpa.free(pdevs);
        std.log.scoped(.vk_init).info("found {d} GPUs:", .{pdevs.len});

        var best_pdev: ?vk.PhysicalDevice = null;

        if (drm_fd < 0) {
            std.debug.panic("no drm fd, idk", .{});
        }
        const drm_stat: std.posix.Stat = std.posix.fstat(drm_fd) catch {
            return error.DrmStatFailed;
        };

        for (pdevs) |pdev| {
            const props = self.instance.getPhysicalDeviceProperties(pdev);

            std.log.scoped(.vk_init).info(" - {s}", .{std.mem.sliceTo(&props.device_name, 0)});

            if (props.api_version < vk.API_VERSION_1_1) {
                continue;
            }

            const avail_exts = try self.instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, gpa);
            defer gpa.free(avail_exts);

            if (!hasPhysDeviceExtensions(avail_exts)) {
                continue;
            }

            // for (avail_exts) |ext| {
            //     std.log.info("{s}", .{std.mem.sliceTo(&ext.extension_name, 0)});
            // }

            const has_drm_props = hasExtension(avail_exts, vk.extensions.ext_physical_device_drm.name);
            const has_driver_props = hasExtension(avail_exts, vk.extensions.khr_driver_properties.name);

            var props2 = vk.PhysicalDeviceProperties2{
                .properties = undefined,
            };
            var drm_props = vk.PhysicalDeviceDrmPropertiesEXT{
                .has_primary = undefined,
                .has_render = undefined,
                .primary_major = undefined,
                .primary_minor = undefined,
                .render_major = undefined,
                .render_minor = undefined,
            };
            var driver_props = vk.PhysicalDeviceDriverProperties{
                .driver_id = undefined,
                .driver_name = undefined,
                .driver_info = undefined,
                .conformance_version = undefined,
            };
            if (has_drm_props) {
                props2.p_next = &drm_props;
            }
            if (has_driver_props) {
                driver_props.p_next = props2.p_next;
                props2.p_next = &driver_props;
            }

            self.instance.getPhysicalDeviceProperties2(
                pdev,
                &props2,
            );

            // std.log.info("{} {}", .{ has_drm_props, has_driver_props });

            // std.log.info("props2: {any}", .{props2});
            // if (has_drm_props) {
            //     std.log.info("drm_props: {any}", .{drm_props});
            // }
            // if (has_driver_props) {
            //     std.log.info("driver_props: {any}", .{driver_props});
            // }

            var matches_drm_fd: bool = undefined;
            if (drm_fd >= 0) {
                if (!has_drm_props) {
                    std.log.debug("   - unsuitable: doesnt support DRM device", .{});
                    continue;
                }

                const primary_devid = makedev(drm_props.primary_major, drm_props.primary_minor);
                const render_devid = makedev(drm_props.render_major, drm_props.render_minor);
                // std.log.info("{} {} {}", .{ primary_devid, render_devid, drm_stat.rdev });
                matches_drm_fd = primary_devid == drm_stat.rdev or render_devid == drm_stat.rdev;
            } else {
                matches_drm_fd = props.device_type == .cpu;
            }

            if (!matches_drm_fd) {
                std.log.debug("   - unsuitable: doesnt match DRM device", .{});
                continue;
            }

            std.log.scoped(.vk_init).info("   - ^ suitable ^", .{});
            if (best_pdev == null) {
                // TODO: compare
                best_pdev = pdev;
            }

            // break;
        }

        self.pdev = best_pdev orelse {
            return error.NoSuitableGpus;
        };
    }

    fn createDevice(self: *Self) !void {
        const avail_exts = try self.vki.enumerateDeviceExtensionPropertiesAlloc(self.pdev, null, gpa);
        defer gpa.free(avail_exts);

        for (avail_exts) |ext| {
            std.log.info(" - {s}", .{std.mem.sliceTo(&ext.extension_name, 0)});
        }

        var extension_names_buffer: [32][*:0]const u8 = undefined;
        var extension_names: std.ArrayListUnmanaged([*:0]const u8) = .{
            .items = extension_names_buffer[0..0],
            .capacity = extension_names_buffer.len,
        };
        extension_names.appendAssumeCapacity(vk.extensions.khr_external_memory_fd.name);
        extension_names.appendAssumeCapacity(vk.extensions.khr_image_format_list.name);
        extension_names.appendAssumeCapacity(vk.extensions.ext_external_memory_dma_buf.name);
        extension_names.appendAssumeCapacity(vk.extensions.ext_queue_family_foreign.name);
        extension_names.appendAssumeCapacity(vk.extensions.ext_image_drm_format_modifier.name);
        extension_names.appendAssumeCapacity(vk.extensions.khr_timeline_semaphore.name);
        extension_names.appendAssumeCapacity(vk.extensions.khr_synchronization_2.name);

        if (hasExtensions(avail_exts, extension_names.items)) |missing| {
            std.log.err("missing device extension: {s}", .{missing});
            return error.MissingDeviceExtensions;
        }

        const queue_props = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, gpa);
        defer gpa.free(queue_props);

        self.graphics_queue_family = findQueue(queue_props, .{ .graphics_bit = true }) orelse {
            std.log.err("missing graphics queue", .{});
            return error.MissingGraphicsQueue;
        };

        var exportable_semaphore = false;
        var importable_semaphore = false;
        const has_external_semaphore_fd = hasExtension(avail_exts, vk.extensions.khr_external_semaphore_fd.name);
        if (has_external_semaphore_fd) {
            var props = vk.ExternalSemaphoreProperties{
                .export_from_imported_handle_types = undefined,
                .compatible_handle_types = undefined,
            };
            self.vki.getPhysicalDeviceExternalSemaphoreProperties(
                self.pdev,
                &.{
                    .handle_type = .{ .sync_fd_bit = true },
                },
                &props,
            );
            exportable_semaphore = props.external_semaphore_features.exportable_bit;
            importable_semaphore = props.external_semaphore_features.importable_bit;
            extension_names.appendAssumeCapacity(vk.extensions.khr_external_semaphore_fd.name);
        }
        if (!exportable_semaphore) {
            std.log.info("not exportable_semaphore", .{});
        }
        if (!importable_semaphore) {
            std.log.info("not importable_semaphore", .{});
        }

        // FIXME:
        const dmabuf_sync_file_import_export = true;
        // const dmabuf_sync_file_import_export = dmabuf_check_sync_file_import_export();
        // std.log.info("dmabuf_sync_file_import_export={}", .{dmabuf_sync_file_import_export});

        self.sync_file_import_export = exportable_semaphore and importable_semaphore;
        self.implicit_sync_interop = self.sync_file_import_export and dmabuf_sync_file_import_export;
        if (self.implicit_sync_interop) {
            std.log.info("using implicit sync", .{});
        } else {
            std.log.info("not using implicit sync, using blocking fallback", .{});
        }

        var pdev_sampler_ycbcr_features = vk.PhysicalDeviceSamplerYcbcrConversionFeatures{};
        var pdev_features = vk.PhysicalDeviceFeatures2{
            .features = undefined,
            .p_next = &pdev_sampler_ycbcr_features,
        };
        self.vki.getPhysicalDeviceFeatures2(self.pdev, &pdev_features);
        self.sampler_ycbcr_conversion = pdev_sampler_ycbcr_features.sampler_ycbcr_conversion != 0;
        std.log.info("sampler YCbCr conversion {s}", .{if (self.sampler_ycbcr_conversion) "supported" else "unsupported"});

        var queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = self.graphics_queue_family,
            .queue_count = 1,
            .p_queue_priorities = &.{1.0},
        };

        const global_priority_create_info = vk.DeviceQueueGlobalPriorityCreateInfoKHR{
            .global_priority = .high_khr,
        };
        const has_global_priority = hasExtension(avail_exts, vk.extensions.khr_global_priority.name);
        if (has_global_priority) {
            queue_create_info.p_next = &global_priority_create_info;
            extension_names.appendAssumeCapacity(vk.extensions.khr_global_priority.name);
            std.log.info("Requesting high priority graphics queue", .{});
        } else {
            std.log.info("Global priority not supported, using fallback regular priority", .{});
        }

        var sampler_ycbcr_features = vk.PhysicalDeviceSamplerYcbcrConversionFeatures{
            .sampler_ycbcr_conversion = @intFromBool(self.sampler_ycbcr_conversion),
        };
        var sync2_features = vk.PhysicalDeviceSynchronization2FeaturesKHR{
            .p_next = &sampler_ycbcr_features,
            .synchronization_2 = vk.TRUE,
        };
        var timeline_features = vk.PhysicalDeviceTimelineSemaphoreFeaturesKHR{
            .p_next = &sync2_features,
            .timeline_semaphore = vk.TRUE,
        };

        // vk.PhysicalDeviceVulkan13Features{
        //     .synchronization_2 = vk.TRUE,
        // };
        // vk.PhysicalDeviceVulkan12Features{
        //     .timeline_semaphore = vk.TRUE,
        // };

        var device_create_info = vk.DeviceCreateInfo{
            .p_next = &timeline_features,
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_create_info),
            .enabled_extension_count = @truncate(extension_names.items.len),
            .pp_enabled_extension_names = extension_names.items.ptr,
        };

        std.log.info("ext count: {}", .{extension_names.items.len});
        for (extension_names.items) |ext| {
            std.log.info("ext: {s}", .{ext});
        }

        if (hasExtensions(avail_exts, extension_names.items)) |missing| {
            std.log.info("missing ext: {s}", .{missing});
        }

        self.device = self.vki.createDevice(self.pdev, &device_create_info, null) catch |e| device: {
            std.log.info("first createDevice error: {}", .{e});
            if (has_global_priority and (e == error.Unknown or e == error.InitializationFailed)) {
                std.log.info("Did not get a high priority graphics queue, using fallback regular priority", .{});
                queue_create_info.p_next = null;
                extension_names.items.len -= 1;

                break :device self.vki.createDevice(self.pdev, &device_create_info, null) catch |err| {
                    std.log.info("second createDevice error: {}", .{err});
                    return err;
                };
            }

            return e;
        };

        std.log.info("found graphics queue: {}", .{queue_props[self.graphics_queue_family]});
    }

    fn findQueue(queue_props: []const vk.QueueFamilyProperties, contains: vk.QueueFlags) ?u32 {
        var queue_index: u32 = 0;
        var found = false;
        // find the most specific graphics queue
        // because the more generic the queue is, the slower it usually is
        var queue_generality: usize = std.math.maxInt(usize);
        for (queue_props, 0..) |queue_prop, i| {
            // std.log.info("queue: {}", .{queue_prop});
            const this_queue_generality = @popCount(queue_prop.queue_flags.intersect(.{
                .graphics_bit = true,
                .compute_bit = true,
                .transfer_bit = true,
            }).toInt());

            if (queue_prop.queue_flags.contains(contains) and
                this_queue_generality <= queue_generality)
            {
                queue_index = @truncate(i);
                queue_generality = this_queue_generality;
                found = true;
            }
        }

        if (!found) {
            return null;
        }

        return queue_index;
    }

    fn hasExtensions(avail_exts: []vk.ExtensionProperties, required: [][*:0]const u8) ?[*:0]const u8 {
        for (required) |ext| {
            if (!hasExtension(avail_exts, std.mem.span(ext))) {
                return ext;
            }
        }

        return null;
    }

    fn hasPhysDeviceExtensions(avail_exts: []vk.ExtensionProperties) bool {
        for (phys_device_extensions) |ext| {
            if (!hasExtension(avail_exts, ext)) {
                return false;
            }
        }

        return true;
    }

    fn hasExtension(avail_exts: []vk.ExtensionProperties, needed: []const u8) bool {
        for (avail_exts) |avail_ext| {
            if (std.mem.eql(u8, needed, std.mem.sliceTo(&avail_ext.extension_name, 0))) {
                return true;
            }
        } else {
            return false;
        }
    }
};

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

    for (phys_device_extensions) |ext| {
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

fn makedev(major: i64, minor: i64) u64 {
    const x = @as(u64, @bitCast(major));
    const y = @as(u64, @bitCast(minor));
    return ((x & 0xFFFF_F000) << 32) | ((x & 0xFFF) << 8) | ((y & 0xFFFF_FF00) << 12) | (y & 0xFF);
}
