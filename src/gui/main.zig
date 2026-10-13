const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const App = @import("app.zig").App;
const backend = @import("backend.zig");
const prefs = @import("preferences.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var options: backend.Options = .{};
    var smoke: ?[]const u8 = null;
    var explicit_cli = false;
    var appearance: ?prefs.Appearance = null;
    var width: ?i32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("PX2 native configuration editor\nUsage: px2-gui [--cli PATH] [--state-dir PATH] [--backup-dir PATH]\n               [--connection auto|direct|receiver] [--device PATH]\n               [--appearance dark|light|system] [--width PIXELS]\n", .{});
            return;
        }
        if (i + 1 >= args.len) return error.MissingOptionValue;
        i += 1;
        const value = args[i];
        const z = try a.dupeZ(u8, value);
        if (std.mem.eql(u8, arg, "--cli")) {
            options.executable = z;
            explicit_cli = true;
        } else if (std.mem.eql(u8, arg, "--state-dir")) options.state_dir = z else if (std.mem.eql(u8, arg, "--backup-dir")) options.backup_dir = z else if (std.mem.eql(u8, arg, "--device")) options.device = z else if (std.mem.eql(u8, arg, "--connection")) {
            if (!std.mem.eql(u8, value, "auto") and !std.mem.eql(u8, value, "direct") and !std.mem.eql(u8, value, "receiver")) return error.InvalidConnection;
            options.connection = z;
        } else if (std.mem.eql(u8, arg, "--appearance")) appearance = std.meta.stringToEnum(prefs.Appearance, value) orelse return error.InvalidAppearance else if (std.mem.eql(u8, arg, "--width")) width = std.math.clamp(try std.fmt.parseInt(i32, value, 10), 390, 3840) else if (std.mem.eql(u8, arg, "--smoke-test")) smoke = value else return error.InvalidOption;
    }
    const home = init.environ_map.get("HOME") orelse return error.MissingHome;
    const config_home = init.environ_map.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(a, &.{ home, ".config" });
    const pref_path = try std.fs.path.join(a, &.{ config_home, "px2/gui.json" });
    const state_home = init.environ_map.get("XDG_STATE_HOME") orelse try std.fs.path.join(a, &.{ home, ".local/state" });
    const default_state = try std.fs.path.join(a, &.{ state_home, "px2" });
    const custom_state = options.state_dir != null and !std.mem.eql(u8, options.state_dir.?, default_state);
    if (options.state_dir == null) options.state_dir = try a.dupeZ(u8, default_state);
    if (!std.fs.path.isAbsolute(options.state_dir.?) or !std.fs.path.isAbsolute(config_home)) return error.ExpectedAbsolutePath;
    // Prefer the matching CLI installed beside this binary, including source builds.
    if (std.mem.eql(u8, options.executable, "px2")) {
        if (glib.fileReadLink("/proc/self/exe", null)) |path| {
            defer glib.free(path);
            const sibling = try std.fs.path.join(a, &.{ std.fs.path.dirname(std.mem.span(path)).?, "px2" });
            const file = gio.File.newForPath(try a.dupeZ(u8, sibling));
            defer file.unref();
            if (file.queryExists(null) != 0) options.executable = try a.dupeZ(u8, sibling);
        }
    }
    if (smoke != null and (!explicit_cli or init.environ_map.get("PX2_GUI_FAKE_DIR") == null)) return error.SmokeRequiresExplicitFakeCli;
    var preferences = prefs.Preferences.load(init.io, a, pref_path);
    if (appearance) |value| preferences.appearance = value;
    if (width) |value| preferences.width = value;
    // Distinct state directories must never activate a window operating on another mouse state.
    const id = if (!custom_state) "io.github.px2.Configurator" else try std.fmt.allocPrintSentinel(a, "io.github.px2.Configurator.s{x}", .{std.hash.Wyhash.hash(0, options.state_dir.?)}, 0);
    const application = gtk.Application.new(id, .{ .non_unique = smoke != null });
    defer application.unref();
    var app: App = .{ .application = application, .options = options, .io = init.io, .preferences = preferences, .preferences_path = pref_path, .custom_state = custom_state, .smoke = smoke };
    defer app.deinit();
    _ = gio.Application.signals.activate.connect(application.as(gio.Application), *App, activate, &app, .{});
    const code = application.as(gio.Application).run(0, null);
    if (code != 0 or app.smoke_failed) return error.GuiFailed;
}
fn activate(_: *gio.Application, app: *App) callconv(.c) void {
    if (app.window) |window| {
        window.present();
        return;
    }
    app.create();
}
