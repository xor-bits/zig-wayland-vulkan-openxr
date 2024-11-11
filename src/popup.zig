const gpa = @import("std").heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("server.zig").Server;

//

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,

    commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(commit),
    destroy: wl.Listener(void) = wl.Listener(void).init(destroy),

    fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (popup.xdg_popup.base.initial_commit) {
            _ = popup.xdg_popup.base.scheduleConfigure();
        }
    }

    fn destroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);

        popup.commit.link.remove();
        popup.destroy.link.remove();

        gpa.destroy(popup);
    }
};

// const Popup = struct {
//     xdg_popup: *wlr.XdgPopup,

//     commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(commit),
//     destroy: wl.Listener(void) = wl.Listener(void).init(destroy),

//     fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
//         const popup: *Popup = @fieldParentPtr("commit", listener);
//         if (popup.xdg_popup.base.initial_commit) {
//             _ = popup.xdg_popup.base.scheduleConfigure();
//         }
//     }

//     fn destroy(listener: *wl.Listener(void)) void {
//         const popup: *Popup = @fieldParentPtr("destroy", listener);

//         popup.commit.link.remove();
//         popup.destroy.link.remove();

//         gpa.destroy(popup);
//     }
// };
