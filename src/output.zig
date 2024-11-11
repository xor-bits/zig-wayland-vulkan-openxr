const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("server.zig").Server;

//

const gpa = std.heap.c_allocator;

//

pub const Output = struct {
    link: wl.list.Link = undefined,
    server: *Server,
    output: *wlr.Output,

    frame: wl.Listener(*wlr.Output) =
        wl.Listener(*wlr.Output).init(frame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) =
        wl.Listener(*wlr.Output.event.RequestState).init(request_state),
    destroy: wl.Listener(*wlr.Output) =
        wl.Listener(*wlr.Output).init(destroy),

    const Self = @This();

    pub fn create(server: *Server, wlr_output: *wlr.Output) !void {
        // a new monitor appeared
        const output = try gpa.create(Self);
        output.* = .{
            .server = server,
            .output = wlr_output,
        };

        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.destroy.add(&output.destroy);

        const layout_output = try server.output_layout.addAuto(wlr_output);
        const scene_output = try server.scene.createSceneOutput(wlr_output);
        server.scene_output_layout.addOutput(layout_output, scene_output);

        // auto arrange new monitors from left to right in order of appearance
        // TODO: let the user configure the monitor layout
        // _ = try server.output_layout.addAuto(wlr_output);
    }

    fn destroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        // a monitor was disconnected
        const output: *Output = @fieldParentPtr("destroy", listener);

        output.frame.link.remove();
        // output.request_state.link.remove(); // TODO: why not this?
        output.destroy.link.remove();

        gpa.destroy(output);
    }

    fn frame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);

        const scene_output = output.server.scene.getSceneOutput(output.output).?;
        _ = scene_output.commit(null);

        var now: std.posix.timespec = undefined;
        std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
        scene_output.sendFrameDone(&now);
    }

    fn request_state(
        listener: *wl.Listener(*wlr.Output.event.RequestState),
        event: *wlr.Output.event.RequestState,
    ) void {
        const output: *Output = @fieldParentPtr("request_state", listener);

        _ = output.output.commitState(event.state);
    }
};

// const Output = struct {
//     server: *Server,
//     wlr_output: *wlr.Output,

//     frame: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(frame),
//     request_state: wl.Listener(*wlr.Output.event.RequestState) =
//         wl.Listener(*wlr.Output.event.RequestState).init(request_state),
//     destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(destroy),

//     // The wlr.Output should be destroyed by the caller on failure to trigger cleanup.
//     fn create(server: *Server, wlr_output: *wlr.Output) !void {
//         const output = try gpa.create(Output);

//         output.* = .{
//             .server = server,
//             .wlr_output = wlr_output,
//         };
//         wlr_output.events.frame.add(&output.frame);
//         wlr_output.events.request_state.add(&output.request_state);
//         wlr_output.events.destroy.add(&output.destroy);

//         const layout_output = try server.output_layout.addAuto(wlr_output);

//         const scene_output = try server.scene.createSceneOutput(wlr_output);
//         scene_output.output.layers;
//         server.scene_output_layout.addOutput(layout_output, scene_output);
//     }

//     fn frame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
//         const output: *Output = @fieldParentPtr("frame", listener);

//         const scene_output = output.server.scene.getSceneOutput(output.wlr_output).?;
//         _ = scene_output.commit(null);

//         var now: std.posix.timespec = undefined;
//         std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
//         scene_output.sendFrameDone(&now);
//     }

//     fn request_state(
//         listener: *wl.Listener(*wlr.Output.event.RequestState),
//         event: *wlr.Output.event.RequestState,
//     ) void {
//         const output: *Output = @fieldParentPtr("request_state", listener);

//         _ = output.wlr_output.commitState(event.state);
//     }

//     fn destroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
//         const output: *Output = @fieldParentPtr("destroy", listener);

//         output.frame.link.remove();
//         output.destroy.link.remove();

//         gpa.destroy(output);
//     }
// };
