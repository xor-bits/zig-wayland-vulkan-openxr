const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const Server = @import("server.zig").Server;

//

const gpa = std.heap.c_allocator;

//

pub const Toplevel = struct {
    link: wl.list.Link = undefined,
    server: *Server,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,

    commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(commit),
    map: wl.Listener(void) = wl.Listener(void).init(map),
    unmap: wl.Listener(void) = wl.Listener(void).init(unmap),
    destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = wl.Listener(*wlr.XdgToplevel.event.Move).init(requestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = wl.Listener(*wlr.XdgToplevel.event.Resize).init(requestResize),

    // mapped: bool,
    loc: struct {
        x: i32,
        y: i32,
    } = .{ .x = 0, .y = 0 },

    const Self = @This();

    pub fn focus(self: *Self, surface: *wlr.Surface) void {
        // only deals with keyboard focus

        const server = self.server;
        const seat = server.seat;

        if (seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface)
                // dont re-focus already focused surface
                return;

            // deactivate the previous surface and let the previous client know
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            }
        }

        // move the window to front
        self.link.remove();
        server.toplevels.prepend(self);
        // set the window as activated
        _ = self.xdg_toplevel.setActivated(true);

        // tell seat & wlr to enter this window with the keyboard
        const wlr_keyboard = server.seat.getKeyboard() orelse return;
        server.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);
        if (toplevel.xdg_toplevel.base.initial_commit) {
            _ = toplevel.xdg_toplevel.setSize(0, 0);
        }
    }

    fn map(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        toplevel.server.toplevels.prepend(toplevel);
        toplevel.focus(toplevel.xdg_toplevel.base.surface);
    }

    fn unmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);
        toplevel.link.remove();
    }

    fn destroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);

        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();

        gpa.destroy(toplevel);
    }

    fn requestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
        const server = toplevel.server;
        server.grabbed_toplevel = toplevel;
        server.cursor_mode = .move;
        server.grab.x = server.cursor.x - @as(f64, @floatFromInt(toplevel.loc.x));
        server.grab.y = server.cursor.y - @as(f64, @floatFromInt(toplevel.loc.y));
    }

    fn requestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        const server = toplevel.server;

        server.grabbed_toplevel = toplevel;
        server.cursor_mode = .resize;
        server.resize_edges = event.edges;

        var box: wlr.Box = undefined;
        toplevel.xdg_toplevel.base.getGeometry(&box);

        const border_x = toplevel.loc.x + box.x + if (event.edges.right) box.width else 0;
        const border_y = toplevel.loc.y + box.y + if (event.edges.bottom) box.height else 0;
        server.grab.x = server.cursor.x - @as(f64, @floatFromInt(border_x));
        server.grab.y = server.cursor.y - @as(f64, @floatFromInt(border_y));

        server.grab_box = box;
        server.grab_box.x += toplevel.loc.x;
        server.grab_box.y += toplevel.loc.y;
    }
};

// const Toplevel = struct {
//     server: *Server,
//     link: wl.list.Link = undefined,
//     xdg_toplevel: *wlr.XdgToplevel,
//     scene_tree: *wlr.SceneTree,

//     x: i32 = 0,
//     y: i32 = 0,

//     commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(commit),
//     map: wl.Listener(void) = wl.Listener(void).init(map),
//     unmap: wl.Listener(void) = wl.Listener(void).init(unmap),
//     destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
//     request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = wl.Listener(*wlr.XdgToplevel.event.Move).init(requestMove),
//     request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = wl.Listener(*wlr.XdgToplevel.event.Resize).init(requestResize),

// };
