const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Output = @import("output.zig").Output;
const Keyboard = @import("keyboard.zig").Keyboard;
// const Pointer = @import("pointer.zig").Pointer;
const Toplevel = @import("toplevel.zig").Toplevel;
const Popup = @import("popup.zig").Popup;

//

const gpa = std.heap.c_allocator;

//

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,
    scene_output_layout: *wlr.SceneOutputLayout,

    socket_buf: [11]u8 = undefined,
    socket: ?[]const u8 = null,

    output_layout: *wlr.OutputLayout,
    outputs: wl.list.Head(Output, .link) = undefined,
    new_output: wl.Listener(*wlr.Output) =
        wl.Listener(*wlr.Output).init(newOutput),

    xdg_shell: *wlr.XdgShell,
    toplevels: wl.list.Head(Toplevel, .link) = undefined,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) =
        wl.Listener(*wlr.XdgToplevel).init(newXdgToplevel),
    new_xdg_popup: wl.Listener(*wlr.XdgPopup) =
        wl.Listener(*wlr.XdgPopup).init(newXdgPopup),

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) =
        wl.Listener(*wlr.Pointer.event.Motion).init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) =
        wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) =
        wl.Listener(*wlr.Pointer.event.Button).init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) =
        wl.Listener(*wlr.Pointer.event.Axis).init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) =
        wl.Listener(*wlr.Cursor).init(cursorFrame),

    seat: *wlr.Seat,
    keyboards: wl.list.Head(Keyboard, .link) = undefined,
    new_input: wl.Listener(*wlr.InputDevice) =
        wl.Listener(*wlr.InputDevice).init(newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) =
        wl.Listener(*wlr.Seat.event.RequestSetCursor).init(requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) =
        wl.Listener(*wlr.Seat.event.RequestSetSelection).init(requestSetSelection),

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_toplevel: ?*Toplevel = null,
    grab: struct {
        x: f64,
        y: f64,
    } = .{ .x = 0.0, .y = 0.0 },
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},

    const Self = @This();

    pub fn init(server: *Self) anyerror!void {
        // wayland display is managed by libwayland,
        // it handles accepting clients from the unix socket,
        // managing wayland globals, and so on
        const wl_server = try wl.Server.create();

        // backens is a wlroots feature that abstracts the input and output hardware
        // autocreate creates the most suitable backend depending on the current env,
        // like an x11 window if x11 server is running, or a wayland window if another
        // wayland server is running, or whatever
        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);

        // GLes2 (I want to use Vulkan)
        const renderer = try wlr.Renderer.autocreate(backend);

        // wlroots util to manage the (layout) arrangement of physical screens
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();
        const scene_output_layout = try scene.attachOutputLayout(output_layout);

        // ready made wlroots handlers
        // compositor allocates surfaces for clients
        _ = try wlr.Compositor.create(wl_server, 6, renderer);
        _ = try wlr.Subcompositor.create(wl_server);
        // data device manager handles clipboard, clients cannot use the clipboard without approval
        _ = try wlr.DataDeviceManager.create(wl_server);

        const allocator = try wlr.Allocator.autocreate(backend, renderer);

        server.* = Self{
            .wl_server = wl_server,
            .backend = backend,
            .renderer = renderer,
            .allocator = allocator,
            .scene = scene,
            .scene_output_layout = scene_output_layout,

            .output_layout = output_layout,

            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
            .seat = try wlr.Seat.create(wl_server, "default"),
        };

        try server.renderer.initServer(server.wl_server);

        // listener for new outputs
        server.outputs.init();
        server.backend.events.new_output.add(&server.new_output);

        // list of windows + xdg-shell (protocol for app windows)
        server.toplevels.init();
        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);

        // let wlroots handle the cursor image on screen
        server.cursor.attachOutputLayout(server.output_layout);

        // let wlroots handle xcursor themes
        try server.cursor_mgr.load(1);

        // wlr_cursor *only* displays the cursor image, it doesnt move it
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);

        // set up a seat, seat = up to 1 keyboard, pointer, touch and drawing tablet
        server.keyboards.init();
        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
    }

    pub fn deinit(server: *Self) void {
        server.wl_server.destroyClients();
        server.wl_server.destroy();
    }

    pub fn start(self: *Self) ![]const u8 {
        if (self.socket) |socket| {
            return socket;
        }

        // add a unix socket to the wayland display
        const socket = try self.wl_server.addSocketAuto(&self.socket_buf);
        self.socket = socket;

        // start the backend, this will go through all inputs and outputs and create take the DRM
        try self.backend.start();

        return socket;
    }

    pub fn run(self: *Self) void {
        self.wl_server.run();
    }

    // new display or monitor available
    fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Self = @fieldParentPtr("new_output", listener);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        state.setEnabled(true);
        if (!wlr_output.commitState(&state)) return;

        Output.create(server, wlr_output) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Self = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        // Don't add the toplevel to server.toplevels until it is mapped
        const toplevel = gpa.create(Toplevel) catch {
            std.log.err("failed to allocate new toplevel", .{});
            return;
        };

        toplevel.* = .{
            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
                gpa.destroy(toplevel);
                std.log.err("failed to allocate new toplevel", .{});
                return;
            },
        };
        toplevel.scene_tree.node.data = @intFromPtr(toplevel);
        xdg_surface.data = @intFromPtr(toplevel.scene_tree);

        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
    }

    fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const xdg_surface = xdg_popup.base;

        // These asserts are fine since tinywl.zig doesn't support anything else that can
        // make xdg popups (e.g. layer shell).
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrFromInt(parent.data)) orelse {
            // The xdg surface user data could be left null due to allocation failure.
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = @intFromPtr(scene_tree);

        const popup = gpa.create(Popup) catch {
            std.log.err("failed to allocate new popup", .{});
            return;
        };
        popup.* = .{
            .xdg_popup = xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    const ViewAtResult = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    fn viewAt(server: *Self, lx: f64, ly: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*Toplevel, @ptrFromInt(n.node.data))) |toplevel| {
                    return ViewAtResult{
                        .toplevel = toplevel,
                        .surface = scene_surface.surface,
                        .sx = sx,
                        .sy = sy,
                    };
                }
            }
        }
        return null;
    }

    fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Self = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => Keyboard.create(server, device) catch |err| {
                std.log.err("failed to create keyboard: {}", .{err});
                return;
            },
            .pointer => server.cursor.attachInputDevice(device),
            else => {},
        }

        server.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.keyboards.length() > 0,
        });
    }

    fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const server: *Self = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == server.seat.pointer_state.focused_client)
            server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const server: *Self = @fieldParentPtr("request_set_selection", listener);
        server.seat.setSelection(event.source, event.serial);
    }

    fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const server: *Self = @fieldParentPtr("cursor_motion", listener);
        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const server: *Self = @fieldParentPtr("cursor_motion_absolute", listener);
        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn processCursorMotion(server: *Self, time_msec: u32) void {
        switch (server.cursor_mode) {
            .passthrough => if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else {
                server.cursor.setXcursor(server.cursor_mgr, "default");
                server.seat.pointerClearFocus();
            },
            .move => {
                const toplevel = server.grabbed_toplevel.?;
                toplevel.loc.x = @as(i32, @intFromFloat(server.cursor.x - server.grab.x));
                toplevel.loc.y = @as(i32, @intFromFloat(server.cursor.y - server.grab.y));
                toplevel.scene_tree.node.setPosition(toplevel.loc.x, toplevel.loc.y);
            },
            .resize => {
                const toplevel = server.grabbed_toplevel.?;
                const border_x = @as(i32, @intFromFloat(server.cursor.x - server.grab.x));
                const border_y = @as(i32, @intFromFloat(server.cursor.y - server.grab.y));

                var new_left = server.grab_box.x;
                var new_right = server.grab_box.x + server.grab_box.width;
                var new_top = server.grab_box.y;
                var new_bottom = server.grab_box.y + server.grab_box.height;

                if (server.resize_edges.top) {
                    new_top = border_y;
                    if (new_top >= new_bottom)
                        new_top = new_bottom - 1;
                } else if (server.resize_edges.bottom) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top)
                        new_bottom = new_top + 1;
                }

                if (server.resize_edges.left) {
                    new_left = border_x;
                    if (new_left >= new_right)
                        new_left = new_right - 1;
                } else if (server.resize_edges.right) {
                    new_right = border_x;
                    if (new_right <= new_left)
                        new_right = new_left + 1;
                }

                var geo_box: wlr.Box = undefined;
                toplevel.xdg_toplevel.base.getGeometry(&geo_box);
                toplevel.loc.x = new_left - geo_box.x;
                toplevel.loc.y = new_top - geo_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.loc.x, toplevel.loc.y);

                const new_width = new_right - new_left;
                const new_height = new_bottom - new_top;
                _ = toplevel.xdg_toplevel.setSize(new_width, new_height);
            },
        }
    }

    fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const server: *Self = @fieldParentPtr("cursor_button", listener);
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            server.cursor_mode = .passthrough;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            res.toplevel.focus(res.surface);
            // server.focusView(res.toplevel, res.surface);
        }
    }

    fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const server: *Self = @fieldParentPtr("cursor_axis", listener);
        server.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Self = @fieldParentPtr("cursor_frame", listener);
        server.seat.pointerNotifyFrame();
    }

    /// Assumes the modifier used for compositor keybinds is pressed
    /// Returns true if the key was handled
    pub fn handleKeybind(server: *Self, key: xkb.Keysym) bool {
        switch (@intFromEnum(key)) {
            // Exit the compositor
            xkb.Keysym.Escape => server.wl_server.terminate(),
            // Focus the next toplevel in the stack, pushing the current top to the back
            xkb.Keysym.F1 => {
                if (server.toplevels.length() < 2) return true;
                const toplevel: *Toplevel = @fieldParentPtr("link", server.toplevels.link.prev.?);
                toplevel.focus(toplevel.xdg_toplevel.base.surface);
                // server.focus(toplevel, );
            },
            else => return false,
        }
        return true;
    }
};
