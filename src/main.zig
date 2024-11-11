const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const graphics = @import("graphics.zig");

const Server = @import("server.zig").Server;
// const output = @import("output.zig");
// const keyboard = @import("keyboard.zig");
// const pointer = @import("pointer.zig");
// const toplevel = @import("toplevel.zig");
// const popup = @import("popup.zig");

const gpa = std.heap.c_allocator;

pub fn main() anyerror!void {
    wlr.log.init(.debug, null);

    var cmd: []const u8 = "alacritty";
    if (std.os.argv.len >= 2) {
        cmd = std.mem.span(std.os.argv[1]);
    }
    std.log.info("init cmd: {s}", .{cmd});

    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    const socket = try server.start();

    try spawn(cmd, socket);

    std.log.info("running on WAYLAND_DISPLAY={s}", .{socket});
    server.wl_server.run();
}

fn spawn(cmd: []const u8, socket: []const u8) !void {
    // _ = .{ cmd, socket };
    var child = std.process.Child.init(&.{cmd}, gpa);
    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", socket);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}
