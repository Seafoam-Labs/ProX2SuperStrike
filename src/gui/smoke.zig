//! Native integration driver. Requires an explicitly selected fake CLI and fixture directory.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const model = @import("model.zig");
fn require(app: anytype, condition: bool, name: []const u8) bool {
    if (condition) return true;
    std.log.err("GUI smoke failed: {s}", .{name});
    app.smoke_failed = true;
    app.application.as(gio.Application).quit();
    return false;
}
fn quit(app: anytype) void {
    app.application.as(gio.Application).quit();
}
pub fn step(app: anytype) void {
    const mode = app.smoke.?;
    if (std.mem.eql(u8, mode, "readonly")) {
        _ = require(app, !app.online and app.apply.as(gtk.Widget).getSensitive() == 0, "unavailable snapshot must disable writes");
        quit(app);
        return;
    }
    if (std.mem.eql(u8, mode, "invalidstate")) {
        _ = require(app, !app.watch_valid and app.apply.as(gtk.Widget).getSensitive() == 0, "invalid desired state must disable writes");
        quit(app);
        return;
    }
    if (!require(app, app.snapshot != null, "snapshot loaded")) return;
    if (std.mem.startsWith(u8, mode, "capture")) {
        if (app.smoke_step == 0) {
            if (std.mem.endsWith(u8, mode, "hits")) app.navigate(.{ .page = .hits });
            if (std.mem.endsWith(u8, mode, "restoration")) app.navigate(.{ .page = .restoration });
            app.smoke_step = 1;
            return;
        }
        if (app.smoke_ticks < 6) return;
        const window = app.window.?;
        const snapshot = gtk.Snapshot.new();
        window.as(gtk.Widget).snapshotChild(app.root.as(gtk.Widget), snapshot);
        if (snapshot.freeToNode()) |node| {
            defer node.unref();
            const renderer = window.as(gtk.Native).getRenderer().?;
            const texture = renderer.renderTexture(node, null);
            defer texture.unref();
            const path = std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/native.png", .{app.options.state_dir.?}, 0) catch unreachable;
            defer std.heap.page_allocator.free(path);
            _ = require(app, texture.saveToPng(path) != 0, "native screenshot saved");
        } else _ = require(app, false, "native render node available");
        quit(app);
        return;
    }
    if (std.mem.eql(u8, mode, "partial") or std.mem.eql(u8, mode, "conflict") or std.mem.eql(u8, mode, "slow")) {
        if (app.smoke_step == 0) {
            app.dpi.?.setValue(2400);
            if (std.mem.eql(u8, mode, "partial")) app.rate.?.setSelected(4);
            app.smoke_step = 1;
            app.beginApply();
            return;
        }
        if (std.mem.eql(u8, mode, "partial")) {
            if (!require(app, app.base.dpi == 2400 and app.base.rate == 1000 and app.draft.rate == 2000 and model.dirty(app.base, app.draft).count() == 1, "partial write retained pending rate")) return;
        } else if (std.mem.eql(u8, mode, "conflict")) {
            if (!require(app, app.conflict and app.base.dpi == 800 and app.draft.dpi == 2400, "external change blocks first write")) return;
        } else if (!require(app, app.base.dpi == 2400 and app.smoke_close_checked, "close deferred while slow operation completed")) return;
        quit(app);
        return;
    }
    switch (app.smoke_step) {
        0 => {
            if (!require(app, app.selected == 1 and app.apply.as(gtk.Widget).getSensitive() == 0, "initial state")) return;
            app.dpi.?.setValue(2400);
            if (!require(app, app.apply.as(gtk.Widget).getSensitive() != 0, "staged edit enabled Apply")) return;
            app.navigate(.{ .profile = 2 });
            if (!require(app, app.dialog != null, "dirty navigation confirmation")) return;
            app.dialog.?.response(@intFromEnum(gtk.ResponseType.cancel));
            if (!require(app, app.selected == 1 and app.draft.dpi == 2400, "cancel retained draft")) return;
            app.beginApply();
            app.smoke_step = 1;
        },
        1 => {
            if (!require(app, app.base.dpi == 2400 and model.dirty(app.base, app.draft).count() == 0, "DPI save reconciled")) return;
            app.navigate(.{ .profile = 2 });
            app.dpi.?.setValue(3200);
            app.beginApply();
            app.smoke_step = 2;
        },
        2 => {
            if (!require(app, app.snapshot.?.value.active_profile == 1 and app.base.dpi == 3200, "inactive edit did not activate")) return;
            app.navigate(.{ .page = .hits });
            if (!require(app, app.hit_controls[0] == null, "inactive HITS unavailable")) return;
            app.navigate(.activate);
            app.smoke_step = 3;
        },
        3 => {
            if (!require(app, app.snapshot.?.value.active_profile == 2, "explicit activation")) return;
            app.hit_controls[2].?.as(gtk.Range).setValue(0);
            app.beginApply();
            app.smoke_step = 4;
        },
        4 => {
            if (!require(app, app.base.hits[0].haptics == 0 and app.base.hits[1].haptics == 4, "left haptics changed independently")) return;
            app.navigate(.{ .profile = 5 });
            if (!require(app, app.dpi.?.as(gtk.Widget).getSensitive() == 0, "factory profile disabled")) return;
            app.navigate(.initialize);
            app.smoke_step = 5;
        },
        5 => {
            if (!require(app, app.dialog != null and !app.snapshot.?.value.profile(5).?.editable, "dry run requires confirmation")) return;
            app.dialog.?.response(@intFromEnum(gtk.ResponseType.accept));
            app.smoke_step = 6;
        },
        6 => {
            if (!require(app, app.snapshot.?.value.profile(5).?.editable and app.backup != null, "initialization and backup result")) return;
            app.navigate(.{ .page = .restoration });
            if (!require(app, app.watch.?.value.running, "watcher status")) return;
            app.navigate(.{ .page = .diagnostics });
            quit(app);
        },
        else => unreachable,
    }
}
