const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("widgets.zig");
const model = @import("model.zig");
const protocol = model.protocol;
const backend = @import("backend.zig");
const prefs = @import("preferences.zig");
const a = std.heap.page_allocator;
const Phase = enum { idle, watch_only, refresh_watch, refresh_snapshot, preflight_watch, preflight_snapshot, conflict_watch, writing, reconcile_snapshot, reconcile_watch, initialize_review, doctor };
const Action = union(enum) { page: model.Page, profile: u8, button: u8, close, initialize, activate };
const Link = struct { app: *App, action: Action };

pub const App = struct {
    application: *gtk.Application,
    options: backend.Options,
    io: std.Io,
    preferences: prefs.Preferences,
    preferences_path: []const u8,
    custom_state: bool,
    smoke: ?[]const u8 = null,
    smoke_failed: bool = false,
    smoke_step: u8 = 0,
    smoke_ticks: u32 = 0,
    smoke_close_checked: bool = false,
    window: ?*gtk.Window = null,
    root: *gtk.Box = undefined,
    workspace: *gtk.Box = undefined,
    sidebar: *gtk.Box = undefined,
    content: *gtk.Box = undefined,
    nav: *gtk.Box = undefined,
    banner: *gtk.Label = undefined,
    title: *gtk.Label = undefined,
    header_title: *gtk.Label = undefined,
    summary: *gtk.Label = undefined,
    footer: *gtk.Label = undefined,
    apply: *gtk.Button = undefined,
    discard: *gtk.Button = undefined,
    refresh_button: *gtk.Button = undefined,
    profile_picker: *gtk.DropDown = undefined,
    appearance_picker: *gtk.DropDown = undefined,
    connection_picker: *gtk.DropDown = undefined,
    dpi: ?*gtk.SpinButton = null,
    rate: ?*gtk.DropDown = null,
    hit_controls: [3]?*gtk.Scale = @splat(null),
    phase: Phase = .idle,
    page: model.Page = .sensitivity,
    selected: u8 = 0,
    hit_button: u8 = 0,
    online: bool = false,
    watch_valid: bool = false,
    snapshot: ?std.json.Parsed(protocol.Snapshot) = null,
    watch: ?std.json.Parsed(protocol.Watch) = null,
    base: model.Draft = .{},
    draft: model.Draft = .{},
    revision: u64 = 0,
    conflict: bool = false,
    queue: model.Queue = .{},
    queue_index: usize = 0,
    operation_failed: bool = false,
    notice: [:0]const u8 = "Connect the mouse to read its configuration.",
    notice_owned: ?[:0]u8 = null,
    details: ?[:0]u8 = null,
    backup: ?[:0]u8 = null,
    last_snapshot: i64 = 0,
    render_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(a),
    rendering: bool = false,
    narrow: bool = false,
    links: [24]Link = undefined,
    link_count: usize = 0,
    pending_action: ?Action = null,
    dialog: ?*gtk.Dialog = null,
    timer: c_uint = 0,
    monitors: [3]?*gio.FileMonitor = @splat(null),
    state_changed: bool = false,
    device_changed: bool = false,
    changed_at: i64 = 0,
    ticks: u32 = 0,
    initialization_confirm: bool = false,

    pub fn deinit(self: *App) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        for (self.monitors) |m| if (m) |watcher| {
            _ = watcher.cancel();
            watcher.unref();
        };
        if (self.dialog) |d| {
            d.as(gtk.Window).destroy();
            d.unref();
        }
        if (self.snapshot) |*s| s.deinit();
        if (self.watch) |*s| s.deinit();
        if (self.notice_owned) |s| a.free(s);
        if (self.details) |s| a.free(s);
        if (self.backup) |s| a.free(s);
        self.render_arena.deinit();
    }
    fn text(self: *App, comptime format: []const u8, args: anytype) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.render_arena.allocator(), format, args, 0) catch "Out of memory";
    }
    fn message(self: *App, text_: []const u8) void {
        const copy = a.dupeZ(u8, text_) catch return;
        if (self.notice_owned) |s| a.free(s);
        self.notice_owned = copy;
        self.notice = copy;
    }
    fn detail(self: *App, bytes: []const u8) void {
        if (self.details) |s| a.free(s);
        const valid = if (std.unicode.utf8ValidateSlice(bytes)) bytes else "px2 returned non-UTF-8 output";
        var end = @min(valid.len, 16000);
        while (end > 0 and !std.unicode.utf8ValidateSlice(valid[0..end])) end -= 1;
        self.details = a.dupeZ(u8, valid[0..end]) catch null;
        if (self.details) |s| for (s) |*c| {
            if (c.* < 32 and c.* != '\n' and c.* != '\t') c.* = ' ';
        };
    }
    pub fn create(self: *App) void {
        const window = gtk.ApplicationWindow.new(self.application).as(gtk.Window);
        self.window = window;
        window.setTitle("PX2 Configuration");
        window.setDefaultSize(self.preferences.width, self.preferences.height);
        window.setIconName("io.github.px2.Configurator");
        const css = gtk.CssProvider.new();
        defer css.unref();
        css.loadFromString(@embedFile("style"));
        gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        self.root = w.box(.vertical, 0);
        self.root.as(gtk.Widget).addCssClass("px2-root");
        window.setChild(self.root.as(gtk.Widget));
        const header = gtk.HeaderBar.new();
        const header_title = w.label("PX2 Configuration", null);
        self.header_title = header_title;
        self.narrow = self.preferences.width < 760;
        header_title.setWrap(0);
        header_title.setEllipsize(.end);
        header_title.setWidthChars(1);
        header.setTitleWidget(header_title.as(gtk.Widget));
        self.appearance_picker = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Pearl dark", "Pearl light", "System GTK", null }));
        self.appearance_picker.setSelected(@intFromEnum(self.preferences.appearance));
        w.named(self.appearance_picker, "Appearance");
        header.packEnd(self.appearance_picker.as(gtk.Widget));
        w.append(self.root, header);
        self.workspace = w.box(.horizontal, 0);
        self.workspace.as(gtk.Widget).setVexpand(1);
        w.append(self.root, self.workspace);
        self.sidebar = w.box(.vertical, 12);
        self.sidebar.as(gtk.Widget).addCssClass("sidebar");
        self.sidebar.as(gtk.Widget).setSizeRequest(190, -1);
        w.append(self.workspace, self.sidebar);
        const pane = w.box(.vertical, 0);
        w.expand(pane);
        w.append(self.workspace, pane);
        const toolbar = w.box(.horizontal, 12);
        w.margins(toolbar.as(gtk.Widget), 16);
        self.title = w.label("Configuration", "heading");
        w.expand(self.title);
        w.append(toolbar, self.title);
        self.refresh_button = w.button("Refresh", null);
        w.append(toolbar, self.refresh_button);
        w.append(pane, toolbar);
        self.profile_picker = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "No profiles", null }));
        w.named(self.profile_picker, "Profile");
        w.margins(self.profile_picker.as(gtk.Widget), 12);
        w.append(pane, self.profile_picker);
        self.nav = w.box(.horizontal, 4);
        w.margins(self.nav.as(gtk.Widget), 12);
        w.append(pane, self.nav);
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        w.append(pane, scroll);
        const body = w.box(.vertical, 16);
        w.margins(body.as(gtk.Widget), 20);
        scroll.setChild(body.as(gtk.Widget));
        self.banner = w.label("", "notice");
        w.append(body, self.banner);
        self.content = w.box(.vertical, 16);
        w.append(body, self.content);
        const footer_box = w.box(.vertical, 8);
        footer_box.as(gtk.Widget).addCssClass("footer");
        w.append(pane, footer_box);
        self.footer = w.label("", "secondary");
        w.append(footer_box, self.footer);
        const buttons = w.box(.horizontal, 8);
        self.discard = w.button("Discard", null);
        self.apply = w.button("Apply changes", "suggested-action");
        w.expand(self.apply);
        w.append(buttons, self.discard);
        w.append(buttons, self.apply);
        w.append(footer_box, buttons);
        self.summary = w.label("Saved profile values · live readings may be stale", "status");
        w.append(self.root, self.summary);
        _ = gtk.Button.signals.clicked.connect(self.refresh_button, *App, refreshClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.discard, *App, discardClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.apply, *App, applyClicked, self, .{});
        _ = object.Object.signals.notify.connect(self.profile_picker.as(object.Object), *App, profileChanged, self, .{ .detail = "selected" });
        _ = object.Object.signals.notify.connect(self.appearance_picker.as(object.Object), *App, appearanceChanged, self, .{ .detail = "selected" });
        _ = gtk.Window.signals.close_request.connect(window, *App, closing, self, .{});
        self.theme();
        self.render();
        window.present();
        self.timer = glib.timeoutAdd(250, tick, self);
        self.monitor(0, self.options.state_dir.?);
        self.monitor(1, "/dev");
        self.beginRefresh();
    }
    fn theme(self: *App) void {
        for ([_][:0]const u8{ "dark", "light", "system" }) |name| self.root.as(gtk.Widget).removeCssClass(name);
        self.root.as(gtk.Widget).addCssClass(@tagName(self.preferences.appearance));
    }
    fn link(self: *App, parent: *gtk.Box, text_: [:0]const u8, action: Action, active: bool) void {
        const b = w.button(text_, if (active) "active" else null);
        w.append(parent, b);
        if (self.narrow) w.expand(b);
        const bound = &self.links[self.link_count];
        self.link_count += 1;
        bound.* = .{ .app = self, .action = action };
        _ = gtk.Button.signals.clicked.connect(b, *Link, navigated, bound, .{});
        w.sensitive(b, self.phase == .idle);
    }
    fn card(self: *App, title_: [:0]const u8) *gtk.Box {
        const value = w.box(.vertical, 12);
        value.as(gtk.Widget).addCssClass("card");
        w.append(value, w.label(title_, "title"));
        w.append(self.content, value);
        return value;
    }
    fn fact(self: *App, parent: *gtk.Box, name: [:0]const u8, value: [:0]const u8) void {
        _ = self;
        const row = w.box(.horizontal, 12);
        const key = w.label(name, "secondary");
        w.expand(key);
        w.append(row, key);
        w.append(row, w.label(value, null));
        w.append(parent, row);
    }
    pub fn render(self: *App) void {
        self.rendering = true;
        defer self.rendering = false;
        w.clear(self.sidebar);
        w.clear(self.content);
        w.clear(self.nav);
        _ = self.render_arena.reset(.retain_capacity);
        self.link_count = 0;
        self.dpi = null;
        self.rate = null;
        self.hit_controls = @splat(null);
        const busy = self.phase != .idle;
        self.header_title.setText(if (self.narrow) "PX2" else "PX2 Configuration");
        w.sensitive(self.profile_picker, !busy);
        w.sensitive(self.refresh_button, !busy);
        w.append(self.sidebar, w.mouseIcon());
        w.append(self.sidebar, w.label("PRO X2\nSUPERSTRIKE", "title"));
        if (self.snapshot) |s| {
            const battery = if (s.value.battery.percent) |p| self.text("{d}%{s}", .{ p, if (s.value.battery.charging) " · charging" else "" }) else "Battery unavailable";
            w.append(self.sidebar, w.label(self.text("{s}\n{s}{s}", .{ s.value.device.connection, battery, if (self.online) "" else " · cached" }), "secondary"));
            w.append(self.sidebar, w.label("ONBOARD PROFILES", "eyebrow"));
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            var selection: u32 = 0;
            for (s.value.profiles, 0..) |p, index| {
                const name = self.text("Profile {d}{s}", .{ p.slot, if (p.slot == s.value.active_profile) " · active" else if (!p.initialized) " · factory" else "" });
                self.link(self.sidebar, name, .{ .profile = p.slot }, p.slot == self.selected);
                names.append(self.render_arena.allocator(), name) catch {};
                if (p.slot == self.selected) selection = @intCast(index);
            }
            names.append(self.render_arena.allocator(), null) catch {};
            const list = gtk.StringList.new(@ptrCast(names.items.ptr));
            defer list.unref();
            self.profile_picker.setModel(list.as(gio.ListModel));
            self.profile_picker.setSelected(selection);
        } else w.append(self.sidebar, w.label("No device snapshot", "secondary"));
        const spacer = w.box(.vertical, 0);
        spacer.as(gtk.Widget).setVexpand(1);
        w.append(self.sidebar, spacer);
        self.link(self.sidebar, "Restoration", .{ .page = .restoration }, self.page == .restoration);
        self.link(self.sidebar, "Diagnostics", .{ .page = .diagnostics }, self.page == .diagnostics);
        self.title.setText(if (self.page == .restoration) "Restoration" else if (self.page == .diagnostics) "Diagnostics" else self.text("Profile {d}", .{self.selected}));
        self.nav.as(gtk.Orientable).setOrientation(if (self.narrow) .vertical else .horizontal);
        const editor_nav = if (self.narrow) w.box(.horizontal, 4) else self.nav;
        if (self.narrow) w.append(self.nav, editor_nav);
        self.link(editor_nav, "Sensitivity", .{ .page = .sensitivity }, self.page == .sensitivity);
        self.link(editor_nav, "Buttons & HITS", .{ .page = .hits }, self.page == .hits);
        if (self.narrow) {
            const status_nav = w.box(.horizontal, 4);
            w.append(self.nav, status_nav);
            self.link(status_nav, "Restoration", .{ .page = .restoration }, self.page == .restoration);
            self.link(status_nav, "Diagnostics", .{ .page = .diagnostics }, self.page == .diagnostics);
        }
        self.sidebar.as(gtk.Widget).setVisible(@intFromBool(!self.narrow));
        self.profile_picker.as(gtk.Widget).setVisible(@intFromBool(self.narrow));
        self.banner.setText(self.notice);
        self.banner.as(gtk.Widget).setVisible(@intFromBool(self.notice.len > 0));
        switch (self.page) {
            .sensitivity => self.sensitivity(),
            .hits => self.hits(),
            .restoration => self.restoration(),
            .diagnostics => self.diagnostics(),
        }
        self.updateFooter();
        if (self.last_snapshot != 0) self.summary.setText(self.text("{s} · snapshot {d}s ago · live DPI/rate unverified", .{ if (self.online) "Saved profile values" else "Cached settings", @divTrunc(glib.getRealTime() - self.last_snapshot, 1000000) }));
    }
    fn editorHeader(self: *App) ?protocol.Snapshot {
        const s = if (self.snapshot) |snapshot| snapshot.value else {
            w.append(self.content, w.label("Wake or connect your mouse, then choose Refresh. Check that the matching px2 CLI and udev access rule are installed.", null));
            return null;
        };
        const p = s.profile(self.selected) orelse {
            w.append(self.content, w.label("This profile is no longer available. Select another profile.", null));
            return null;
        };
        if (!p.editable) {
            w.append(self.content, w.label(self.text("Read-only profile: {s}", .{p.editable_reason orelse "No valid writable image"}), "secondary"));
            if (std.mem.eql(u8, p.rom_health, "valid") and !p.initialized) self.link(self.content, "Initialize from factory…", .initialize, false);
        }
        if (self.selected != s.active_profile) {
            w.append(self.content, w.label("Editing an inactive profile. Saving sensitivity will not activate it. HITS requires activation.", "secondary"));
            if (p.initialized or p.slot == s.active_profile) self.link(self.content, "Activate profile", .activate, false);
        }
        return s;
    }
    fn sensitivity(self: *App) void {
        const s = self.editorHeader() orelse return;
        const p = s.profile(self.selected).?;
        const enabled = self.online and self.watch_valid and self.phase == .idle and p.editable and p.crc_valid;
        const card_ = self.card("Sensor sensitivity");
        self.fact(card_, "Saved on mouse", self.text("X: {d} · Y: {d} DPI", .{ p.dpi_x, p.dpi_y }));
        const range = s.supported.dpi;
        if (range.min >= 100 and range.max >= range.min and range.max <= 44000) {
            w.append(card_, w.label("DPI · linked X and Y", null));
            const spin = gtk.SpinButton.newWithRange(range.min, range.max, @max(range.step, 1));
            self.dpi = spin;
            spin.setValue(self.draft.dpi);
            w.named(spin, "DPI for both X and Y axes");
            w.sensitive(spin, enabled);
            w.append(card_, spin);
            _ = gtk.SpinButton.signals.value_changed.connect(spin, *App, dpiChanged, self, .{});
            w.append(card_, w.label(self.text("{d}–{d} DPI · step {d}. Saving replaces both axes with this value.", .{ range.min, range.max, @max(range.step, 1) }), "secondary"));
        } else w.append(card_, w.label("DPI capabilities unavailable; editing is disabled.", "secondary"));
        const rate_card = self.card("Polling rate");
        self.fact(rate_card, "Saved on mouse", self.text("{d} Hz", .{p.rate_hz}));
        if (s.supported.rates_hz.len > 0) {
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            var selected_rate: u32 = gtk.INVALID_LIST_POSITION;
            for (s.supported.rates_hz, 0..) |hz, index| {
                names.append(self.render_arena.allocator(), self.text("{d} Hz", .{hz})) catch {};
                if (hz == self.draft.rate) selected_rate = @intCast(index);
            }
            names.append(self.render_arena.allocator(), null) catch {};
            const dropdown = gtk.DropDown.newFromStrings(@ptrCast(names.items.ptr));
            self.rate = dropdown;
            dropdown.setSelected(selected_rate);
            w.named(dropdown, "Polling rate");
            w.sensitive(dropdown, enabled);
            w.append(rate_card, dropdown);
            _ = object.Object.signals.notify.connect(dropdown.as(object.Object), *App, rateChanged, self, .{ .detail = "selected" });
        } else w.append(rate_card, w.label("Supported polling rates unavailable.", "secondary"));
        w.append(rate_card, w.label("Higher reporting rates can use more power.", "secondary"));
        w.append(self.content, w.label("Profile writes create a backup and verify the saved bytes. Live readings may be stale after wake.", "secondary"));
    }
    fn hits(self: *App) void {
        const s = self.editorHeader() orelse return;
        const tabs = w.box(.horizontal, 8);
        w.append(self.content, tabs);
        self.link(tabs, "Left button", .{ .button = 0 }, self.hit_button == 0);
        self.link(tabs, "Right button", .{ .button = 1 }, self.hit_button == 1);
        const caps = s.hits.capabilities;
        const enabled = self.online and self.watch_valid and self.phase == .idle and s.active_profile == self.selected and s.profile(self.selected).?.crc_valid;
        const card_ = self.card("Buttons & HITS");
        inline for (model.hit_names, .{ "Actuation", "Rapid trigger", "Haptic feedback" }, 0..) |name, title_, index| {
            const max: u8 = switch (index) {
                0 => caps.max_actuation,
                1 => caps.max_rapid_trigger,
                2 => caps.max_haptics,
                else => unreachable,
            };
            w.append(card_, w.label(title_, null));
            if (@field(self.draft.hits[self.hit_button], name) != null and self.hit_button < caps.button_count and max > (if (index == 2) @as(u8, 0) else @as(u8, 1)) and max <= 63) {
                const scale = gtk.Scale.newWithRange(.horizontal, if (index == 2) 0 else 1, max, 1);
                self.hit_controls[index] = scale;
                scale.setDrawValue(1);
                scale.setDigits(0);
                scale.as(gtk.Range).setValue(@field(self.draft.hits[self.hit_button], name) orelse 0);
                w.named(scale, title_);
                w.sensitive(scale, enabled);
                w.append(card_, scale);
                _ = gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *App, hitChanged, self, .{});
            } else w.append(card_, w.label("Unavailable for this profile or button", "secondary"));
        }
        w.append(card_, w.label("Haptics level 0 turns feedback off. Only changed fields are saved for restoration.", "secondary"));
    }
    fn restoration(self: *App) void {
        const card_ = self.card("Automatic restoration");
        if (self.watch) |watch| {
            const v = watch.value;
            self.fact(card_, "Watcher process", if (v.running) "Running" else "Stopped");
            self.fact(card_, "Saved selection", if (v.desired.sector) |sector| self.text("Profile {d}", .{sector & 0xff}) else "No saved selection");
            self.fact(card_, "Saved connection", self.text("{s}", .{v.desired.connection}));
            if (v.state_error) |err| w.append(card_, w.label(self.text("Invalid desired state: {s}", .{err}), "error"));
            if (v.last_status) |status| {
                self.fact(card_, "Last recorded phase", self.text("{s}{s}", .{ status.phase, if (v.running) "" else " (historical)" }));
                var timestamp: [:0]const u8 = "Never";
                if (status.last_restore_ms) |ms| {
                    if (glib.DateTime.newFromUnixLocal(@divTrunc(ms, 1000))) |date| {
                        defer date.unref();
                        if (date.format("%Y-%m-%d %H:%M:%S %Z")) |str| {
                            defer glib.free(str);
                            timestamp = self.text("{s}", .{str});
                        }
                    }
                }
                self.fact(card_, "Last successful restore", timestamp);
                self.fact(card_, "Live settings verified", if (status.restoration_verified) "Yes" else "No");
                if (status.last_error) |err| w.append(card_, w.label(self.text("Last restore error: {s}", .{err}), "error"));
            }
            const path_label = w.label(self.text("State: {s}", .{v.state_directory}), "secondary");
            path_label.setSelectable(1);
            w.append(card_, path_label);
        } else w.append(card_, w.label("Watcher status unavailable. Refresh to retry.", "secondary"));
        const connection = self.card("Connection preference");
        self.connection_picker = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Automatic", "Direct USB", "LIGHTSPEED receiver", null }));
        const choice = self.options.connection orelse if (self.watch) |v| v.value.desired.connection else "auto";
        self.connection_picker.setSelected(if (std.mem.eql(u8, choice, "direct")) 1 else if (std.mem.eql(u8, choice, "receiver")) 2 else 0);
        w.sensitive(self.connection_picker, self.phase == .idle and self.changes().count() == 0);
        w.append(connection, self.connection_picker);
        w.named(self.connection_picker, "Connection for subsequent PX2 commands");
        _ = object.Object.signals.notify.connect(self.connection_picker.as(object.Object), *App, connectionChanged, self, .{ .detail = "selected" });
        w.append(connection, w.label("Used by subsequent commands; saved for restoration after the next successful active-profile change or activation.", "secondary"));
        const info = self.card("Independent of this window");
        w.append(info, w.label("Closing PX2 leaves the watcher running. Restore status does not independently verify live DPI or polling rate.", "secondary"));
        const command = w.label(if (self.custom_state) "Custom state directory: run px2 watch with this same --state-dir. The default service may use a different directory." else "systemctl --user enable --now px2-watch.service", null);
        command.setSelectable(1);
        w.append(info, command);
    }
    fn diagnostics(self: *App) void {
        const card_ = self.card("Saved and reported values");
        if (self.snapshot) |s| {
            self.fact(card_, "Saved DPI X / Y", self.text("{d} / {d}", .{ s.value.saved.dpi_x, s.value.saved.dpi_y }));
            self.fact(card_, "Reported DPI (may be stale)", self.text("{d} / {d}", .{ s.value.reported.dpi_x, s.value.reported.dpi_y }));
            self.fact(card_, "Saved / reported rate", self.text("{d} / {d} Hz", .{ s.value.saved.rate_hz, s.value.reported.rate_hz }));
            self.fact(card_, "Snapshot", if (self.online) "On demand" else "Cached · device unavailable");
            w.append(card_, w.label(self.text("Device: {s}", .{s.value.device.path}), "secondary"));
        }
        const doctor_button = w.button("Run diagnostics", null);
        w.sensitive(doctor_button, self.phase == .idle);
        w.append(card_, doctor_button);
        _ = gtk.Button.signals.clicked.connect(doctor_button, *App, doctorClicked, self, .{});
        if (self.backup) |backup| {
            const box = self.card("Last backup");
            const l = w.label(backup, null);
            l.setSelectable(1);
            w.append(box, l);
        }
        if (self.details) |details| {
            const box = self.card("Last operation details");
            const l = w.label(details, "secondary");
            l.setSelectable(1);
            w.append(box, l);
        }
        w.append(self.content, w.label("If access is denied, install packaging/70-logitech-superstrike.rules, reload udev rules, and reconnect the mouse. The GUI runs as your desktop user.", "secondary"));
    }
    fn changes(self: *App) model.Dirty {
        return model.dirty(self.base, self.draft);
    }
    fn updateFooter(self: *App) void {
        const n = self.changes().count();
        var buffer: [256]u8 = undefined;
        const label = if (self.phase != .idle) "Waiting for px2… Keep the window open while device operations finish." else std.fmt.bufPrintZ(&buffer, "{d} pending changes · {s}", .{ n, if (self.page == .hits) "Only changed HITS fields are saved." else "Apply saves to the selected profile." }) catch "Pending changes";
        self.footer.setText(label);
        const valid = if (self.snapshot) |s| model.valid(s.value, self.selected, self.base, self.draft) else false;
        w.sensitive(self.apply, n > 0 and valid and self.online and self.watch_valid and self.phase == .idle);
        w.sensitive(self.discard, n > 0 and self.phase == .idle);
        if (n > 0 and !valid and self.phase == .idle) self.footer.setText("Pending values are invalid or unavailable for this profile. Discard or correct them.");
    }
    fn begin(self: *App, phase: Phase, command: model.Command) void {
        if (self.phase != .idle) return;
        self.application.as(gio.Application).hold();
        self.phase = phase;
        if (phase != .watch_only) self.render();
        self.launch(command);
    }
    fn launch(self: *App, command: model.Command) void {
        backend.start(self.options, command, self, completed) catch |err| {
            completed(self, command, .{ .ok = false, .stdout = "", .stderr = "", .failure = @errorName(err) });
        };
    }
    fn next(self: *App, phase: Phase, command: model.Command) void {
        self.phase = phase;
        self.launch(command);
    }
    fn finish(self: *App) void {
        self.phase = .idle;
        self.render();
        self.application.as(gio.Application).release();
    }
    pub fn beginRefresh(self: *App) void {
        self.begin(.refresh_watch, .watch);
    }
    pub fn beginApply(self: *App) void {
        if (self.phase != .idle or !self.online or !self.watch_valid or self.changes().count() == 0) return;
        const s = if (self.snapshot) |snapshot| snapshot.value else return;
        if (!model.valid(s, self.selected, self.base, self.draft)) return;
        self.conflict = false;
        self.operation_failed = false;
        self.begin(.preflight_watch, .watch);
    }
    fn loadWatch(self: *App, bytes: []const u8) bool {
        const parsed = protocol.parse(protocol.Watch, a, bytes) catch |err| {
            self.message(@errorName(err));
            self.watch_valid = false;
            return false;
        };
        if (self.phase == .preflight_watch and parsed.value.desired.revision != self.revision) self.conflict = true;
        if (self.watch) |*v| v.deinit();
        self.watch = parsed;
        self.watch_valid = parsed.value.state_error == null;
        if (!self.watch_valid) self.message("Desired state is invalid. Check Diagnostics and repair the state before writing.");
        if (self.changes().count() == 0 or self.phase == .preflight_watch) self.revision = parsed.value.desired.revision;
        return self.watch_valid;
    }
    fn loadSnapshot(self: *App, bytes: []const u8) bool {
        const parsed = protocol.parse(protocol.Snapshot, a, bytes) catch |err| {
            self.message(@errorName(err));
            self.online = false;
            return false;
        };
        const changed = self.changes();
        if (self.selected == 0) self.selected = parsed.value.active_profile;
        const new_base = model.Draft.from(parsed.value, self.selected);
        if (self.phase == .preflight_snapshot) {
            if (!std.meta.eql(new_base, self.base)) self.conflict = true;
            if (self.snapshot) |old| {
                if (old.value.active_profile != parsed.value.active_profile) self.conflict = true;
                const before = old.value.profile(self.selected);
                const after = parsed.value.profile(self.selected);
                if (before == null or after == null) self.conflict = true else if (before.?.dpi_y != after.?.dpi_y or before.?.editable != after.?.editable or before.?.crc_valid != after.?.crc_valid) self.conflict = true;
            }
        }
        self.draft = model.merge(new_base, self.draft, changed);
        self.base = new_base;
        if (self.snapshot) |*v| v.deinit();
        self.snapshot = parsed;
        self.online = true;
        self.last_snapshot = glib.getRealTime();
        if (changed.count() == 0) if (self.watch) |v| {
            self.revision = v.value.desired.revision;
        };
        return true;
    }
    fn errorResult(self: *App, result: backend.Result) void {
        self.detail(if (result.stderr.len > 0) result.stderr else if (result.failure) |f| f else result.stdout);
        if (result.failure) |failure| {
            self.message(failure);
            return;
        }
        var parsed = protocol.parse(protocol.Reply, a, result.stdout) catch {
            self.message("px2 failed or returned an incompatible response. See Diagnostics for details.");
            return;
        };
        defer parsed.deinit();
        const err = parsed.value.@"error" orelse "Unknown error";
        if (std.mem.eql(u8, err, "AccessDenied") or std.mem.eql(u8, err, "PermissionDenied")) self.message("Mouse access denied. Install the PX2 udev rule and reconnect the mouse.") else if (std.mem.eql(u8, err, "NoDevice") or std.mem.eql(u8, err, "DeviceNotFound") or std.mem.eql(u8, err, "Timeout")) self.message("Mouse unavailable or asleep. Showing cached values; wake or reconnect it, then Refresh.") else self.message(err);
    }
    fn completed(context: *anyopaque, command: model.Command, result: backend.Result) void {
        const self: *App = @ptrCast(@alignCast(context));
        const phase = self.phase;
        if (!result.ok) {
            self.errorResult(result);
            switch (phase) {
                .refresh_watch => {
                    self.watch_valid = false;
                    self.next(.refresh_snapshot, .snapshot);
                    return;
                },
                .watch_only, .preflight_watch, .conflict_watch, .reconcile_watch => self.watch_valid = false,
                .refresh_snapshot, .preflight_snapshot, .reconcile_snapshot => self.online = false,
                .writing => {
                    self.operation_failed = true;
                    self.message("A write failed; its outcome may be partial. Reconciling device state before retry. Details are in Diagnostics.");
                    self.next(.reconcile_snapshot, .snapshot);
                    return;
                },
                else => {},
            }
            if (phase == .reconcile_snapshot) {
                self.message("Write outcome unknown: refresh failed. Pending edits are retained; reconnect and Refresh before retry.");
                self.next(.reconcile_watch, .watch);
                return;
            }
            self.finish();
            return;
        }
        switch (phase) {
            .watch_only => {
                _ = self.loadWatch(result.stdout);
                self.phase = .idle;
                if (self.page == .restoration) self.render() else {
                    self.banner.setText(self.notice);
                    self.banner.as(gtk.Widget).setVisible(@intFromBool(self.notice.len > 0));
                    self.updateFooter();
                }
                self.application.as(gio.Application).release();
            },
            .refresh_watch => {
                _ = self.loadWatch(result.stdout);
                self.next(.refresh_snapshot, .snapshot);
            },
            .refresh_snapshot => {
                if (self.loadSnapshot(result.stdout) and self.watch_valid) self.message("");
                self.finish();
            },
            .conflict_watch => {
                _ = self.loadWatch(result.stdout);
                if (self.watch) |v| self.revision = v.value.desired.revision;
                self.finish();
            },
            .preflight_watch => {
                if (!self.loadWatch(result.stdout)) {
                    self.finish();
                    return;
                }
                self.next(.preflight_snapshot, .snapshot);
            },
            .preflight_snapshot => {
                if (!self.loadSnapshot(result.stdout)) {
                    self.finish();
                    return;
                }
                if (self.conflict) {
                    self.message("Settings changed outside this editor. Review the refreshed values, then Apply again to keep your edits, or Discard to use the saved values.");
                    self.next(.conflict_watch, .watch);
                    return;
                }
                if (!model.valid(self.snapshot.?.value, self.selected, self.base, self.draft)) {
                    self.message("The selected profile or capabilities changed. Review your edits.");
                    self.finish();
                    return;
                }
                self.queue = model.Queue.build(self.selected, self.base, self.draft);
                self.queue_index = 0;
                if (self.queue.len == 0) {
                    self.message("The mouse already has these values.");
                    self.finish();
                    return;
                }
                self.next(.writing, self.queue.items[0]);
            },
            .writing, .initialize_review => {
                var reply = protocol.parse(protocol.Reply, a, result.stdout) catch |err| {
                    self.detail(result.stdout);
                    self.message(@errorName(err));
                    if (phase == .writing) {
                        self.operation_failed = true;
                        self.next(.reconcile_snapshot, .snapshot);
                    } else self.finish();
                    return;
                };
                defer reply.deinit();
                if (!reply.value.ok) {
                    self.errorResult(.{ .ok = false, .stdout = result.stdout, .stderr = result.stderr, .failure = null });
                    if (phase == .writing) {
                        self.operation_failed = true;
                        self.next(.reconcile_snapshot, .snapshot);
                    } else self.finish();
                    return;
                }
                if (reply.value.backup) |backup| {
                    if (self.backup) |old| a.free(old);
                    self.backup = a.dupeZ(u8, backup.path) catch null;
                }
                if (reply.value.backup_dir) |path| {
                    if (self.backup) |old| a.free(old);
                    self.backup = a.dupeZ(u8, path) catch null;
                }
                if (phase == .initialize_review) {
                    self.detail(result.stdout);
                    self.finish();
                    self.ask(.initialize, "Initialize this factory profile?", "PX2 validated the factory template. Initialization writes a writable copy, saves backups, and verifies the committed data. See Diagnostics for the dry-run result.", "Initialize profile");
                    return;
                }
                _ = command;
                self.queue_index += 1;
                if (self.queue_index < self.queue.len) {
                    self.next(.writing, self.queue.items[self.queue_index]);
                    return;
                }
                self.next(.reconcile_snapshot, .snapshot);
            },
            .reconcile_snapshot => {
                if (!self.loadSnapshot(result.stdout)) self.message("Write outcome unknown: no valid readback. Refresh before retry.") else if (self.operation_failed) self.message("The operation stopped after a failure. Readback is refreshed; remaining edits are still pending. Review before retry.") else if (self.changes().count() > 0) self.message("Some values differ from the requested settings. Review pending edits before retry.") else self.message("Changes completed; saved data refreshed. Live DPI and polling rate remain unverified.");
                self.next(.reconcile_watch, .watch);
            },
            .reconcile_watch => {
                _ = self.loadWatch(result.stdout);
                if (self.watch) |v| {
                    self.revision = v.value.desired.revision;
                }
                self.finish();
            },
            .doctor => {
                // Existing doctor JSON predates the versioned snapshot contract.
                const parsed = std.json.parseFromSlice(std.json.Value, a, result.stdout, .{}) catch {
                    self.message("Invalid diagnostic response.");
                    self.finish();
                    return;
                };
                defer parsed.deinit();
                self.detail(result.stdout);
                self.message("Diagnostics captured. Live getters may be stale.");
                self.finish();
            },
            .idle => {},
        }
    }
    pub fn navigate(self: *App, action: Action) void {
        if (self.phase != .idle) return;
        if (self.changes().count() > 0) {
            self.ask(action, "Discard pending changes?", "Your edits have not been applied. Keep editing, or discard them before continuing.", "Discard changes");
            return;
        }
        self.perform(action);
    }
    fn perform(self: *App, action: Action) void {
        switch (action) {
            .page => |page_| self.page = page_,
            .button => |button_| self.hit_button = button_,
            .profile => |slot| {
                self.selected = slot;
                if (self.snapshot) |s| self.base = model.Draft.from(s.value, slot);
                self.draft = self.base;
                self.page = .sensitivity;
            },
            .close => {
                self.savePreferences();
                self.window.?.destroy();
                self.window = null;
                return;
            },
            .activate => {
                if (!self.online or !self.watch_valid) return;
                self.queue = .{};
                self.queue.add(.{ .activate = self.selected });
                self.queue_index = 0;
                self.operation_failed = false;
                self.begin(.writing, self.queue.items[0]);
                return;
            },
            .initialize => {
                if (!self.online or !self.watch_valid) return;
                self.begin(.initialize_review, .{ .initialize = .{ .slot = self.selected, .dry_run = true } });
                return;
            },
        }
        if (self.changes().count() == 0) if (self.watch) |v| {
            self.revision = v.value.desired.revision;
        };
        self.render();
    }
    fn ask(self: *App, action: Action, title_: [:0]const u8, body: [:0]const u8, confirm: [:0]const u8) void {
        if (self.dialog) |d| {
            d.as(gtk.Window).present();
            return;
        }
        self.pending_action = action;
        const dialog = gtk.Dialog.new();
        _ = dialog.ref();
        self.dialog = dialog;
        dialog.as(gtk.Window).setTitle(title_);
        dialog.as(gtk.Window).setTransientFor(self.window);
        dialog.as(gtk.Window).setModal(1);
        dialog.as(gtk.Window).setDefaultSize(440, 220);
        const content = dialog.getContentArea();
        w.margins(content.as(gtk.Widget), 24);
        w.append(content, w.label(body, null));
        _ = dialog.addButton("Keep editing", @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton(confirm, @intFromEnum(gtk.ResponseType.accept));
        dialog.setDefaultResponse(@intFromEnum(gtk.ResponseType.cancel));
        // The button label distinguishes the dry-run confirmation from dirty navigation.
        self.initialization_confirm = std.mem.eql(u8, confirm, "Initialize profile");
        _ = gtk.Dialog.signals.response.connect(dialog, *App, answered, self, .{});
        dialog.as(gtk.Window).present();
    }
    fn answered(dialog: *gtk.Dialog, response: c_int, self: *App) callconv(.c) void {
        self.dialog = null;
        dialog.as(gtk.Window).destroy();
        dialog.unref();
        const action = self.pending_action orelse return;
        self.pending_action = null;
        if (response != @intFromEnum(gtk.ResponseType.accept)) {
            self.render();
            return;
        }
        if (self.initialization_confirm) {
            self.queue = .{};
            self.queue.add(.{ .initialize = .{ .slot = self.selected, .dry_run = false } });
            self.queue_index = 0;
            self.operation_failed = false;
            self.begin(.writing, self.queue.items[0]);
        } else {
            self.draft = self.base;
            self.perform(action);
        }
    }
    fn savePreferences(self: *App) void {
        if (self.smoke != null) return;
        if (self.window) |window| {
            self.preferences.width = @max(390, window.as(gtk.Widget).getWidth());
            self.preferences.height = @max(400, window.as(gtk.Widget).getHeight());
        }
        self.preferences.save(self.io, a, self.preferences_path) catch |err| {
            std.log.warn("GUI preferences not saved: {s}", .{@errorName(err)});
        };
    }
    pub fn closing(_: *gtk.Window, self: *App) callconv(.c) c_int {
        if (self.phase != .idle) {
            self.message("An operation is still running. Keep this window open until it finishes; device writes are never force-cancelled.");
            self.banner.setText(self.notice);
            self.banner.as(gtk.Widget).setVisible(1);
            return 1;
        }
        self.navigate(.close);
        return 1;
    }
    fn navigated(_: *gtk.Button, link_: *Link) callconv(.c) void {
        const app = link_.app;
        const action = link_.action;
        app.navigate(action);
    }
    fn refreshClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.beginRefresh();
    }
    pub fn discardClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.draft = self.base;
        if (self.watch) |v| {
            self.revision = v.value.desired.revision;
        }
        self.render();
    }
    fn applyClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.beginApply();
    }
    fn doctorClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.begin(.doctor, .doctor);
    }
    fn dpiChanged(spin: *gtk.SpinButton, self: *App) callconv(.c) void {
        if (self.rendering or self.phase != .idle) return;
        self.draft.dpi = @intCast(std.math.clamp(spin.getValueAsInt(), 0, 65535));
        self.updateFooter();
    }
    fn rateChanged(_: *object.Object, _: *object.ParamSpec, self: *App) callconv(.c) void {
        if (self.rendering or self.phase != .idle) return;
        const index = self.rate.?.getSelected();
        const s = self.snapshot.?.value;
        if (index < s.supported.rates_hz.len) self.draft.rate = s.supported.rates_hz[index];
        self.updateFooter();
    }
    fn hitChanged(changed: *gtk.Range, self: *App) callconv(.c) void {
        if (self.rendering or self.phase != .idle) return;
        inline for (model.hit_names, 0..) |name, index| if (self.hit_controls[index]) |scale| {
            if (changed == scale.as(gtk.Range)) @field(self.draft.hits[self.hit_button], name) = @intFromFloat(changed.getValue());
        };
        self.updateFooter();
    }
    fn profileChanged(_: *object.Object, _: *object.ParamSpec, self: *App) callconv(.c) void {
        if (self.rendering or self.phase != .idle) return;
        const index = self.profile_picker.getSelected();
        if (self.snapshot) |s| if (index < s.value.profiles.len) self.navigate(.{ .profile = s.value.profiles[index].slot });
    }
    fn appearanceChanged(_: *object.Object, _: *object.ParamSpec, self: *App) callconv(.c) void {
        self.preferences.appearance = @enumFromInt(self.appearance_picker.getSelected());
        self.theme();
        self.savePreferences();
    }
    fn connectionChanged(_: *object.Object, _: *object.ParamSpec, self: *App) callconv(.c) void {
        if (self.rendering or self.phase != .idle) return;
        self.options.connection = ([_][:0]const u8{ "auto", "direct", "receiver" })[self.connection_picker.getSelected()];
        self.online = false;
        self.beginRefresh();
    }
    fn monitor(self: *App, index: usize, path: [:0]const u8) void {
        const file = gio.File.newForPath(path);
        defer file.unref();
        const m = file.monitorDirectory(.{}, null, null) orelse return;
        self.monitors[index] = m;
        _ = gio.FileMonitor.signals.changed.connect(m, *App, fileChanged, self, .{});
    }
    fn fileChanged(monitor_: *gio.FileMonitor, file: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, self: *App) callconv(.c) void {
        const name = file.getBasename() orelse return;
        defer glib.free(name);
        const basename = std.mem.span(name);
        if (self.monitors[1] == monitor_) {
            if (!std.mem.startsWith(u8, basename, "hidraw")) return;
            self.device_changed = true;
        } else {
            if (!std.mem.eql(u8, basename, "desired.json") and !std.mem.eql(u8, basename, "watch-status.json")) return;
            self.state_changed = true;
        }
        self.changed_at = glib.getMonotonicTime();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.window == null) {
            self.timer = 0;
            return 0;
        }
        self.ticks +%= 1;
        const narrow = self.window.?.as(gtk.Widget).getWidth() < 760;
        if (narrow != self.narrow and self.dialog == null) {
            self.narrow = narrow;
            self.render();
        }
        if (self.smoke != null) {
            self.smokeTick();
            return 1;
        }
        if (self.phase != .idle or self.dialog != null) return 1;
        if (self.monitors[0] == null and self.ticks % 20 == 0) self.monitor(0, self.options.state_dir.?);
        if ((self.device_changed or self.state_changed) and glib.getMonotonicTime() - self.changed_at > 500000) {
            const device = self.device_changed;
            self.device_changed = false;
            self.state_changed = false;
            if (device) {
                self.online = false;
                self.message("Device connection changed. Cached values are shown until you choose Refresh.");
                self.render();
            }
            self.begin(.watch_only, .watch);
        } else if (self.ticks % 20 == 0) {
            // Local watcher presence only: never poll HID while the mouse is idle.
            self.begin(.watch_only, .watch);
        }
        return 1;
    }
    fn smokeTick(self: *App) void {
        self.smoke_ticks += 1;
        if (self.smoke_ticks > 160) {
            self.smoke_failed = true;
            self.application.as(gio.Application).quit();
            return;
        }
        if (self.phase != .idle) {
            if (std.mem.eql(u8, self.smoke.?, "slow") and self.phase == .writing and !self.smoke_close_checked) {
                self.smoke_close_checked = closing(self.window.?, self) == 1 and self.window != null;
            }
            return;
        }
        @import("smoke.zig").step(self);
    }
};
