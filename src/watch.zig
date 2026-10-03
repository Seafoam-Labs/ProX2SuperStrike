const std = @import("std");
const state = @import("state.zig");
const discovery = @import("discovery.zig");
const restore = @import("restore.zig");
const Device = @import("device.zig").Device;

pub const Options = struct {
    connection: ?discovery.Filter = null,
    device_path: ?[]const u8 = null,
    timeout_ms: u32 = 750,
    idle_ms: i64 = 30_000,
    trace: bool = false,
};

pub const Event = enum { ignored, activity, connected, disconnected, notification };

// HID++ replies have a nonzero software ID. Ignore them, including replies to
// other px2 processes, so our own restoration cannot schedule itself again.
// The legacy 0x41 connection flags follow Solaar's notifications.py handling.
pub fn classify(bytes: []const u8) Event {
    if (bytes.len == 0) return .ignored;
    if ((bytes[0] == 0x10 and bytes.len == 7) or (bytes[0] == 0x11 and bytes.len == 20)) {
        if (bytes[2] == 0x41 and bytes[3] != 0)
            return if (bytes[4] & 0x40 == 0) .connected else .disconnected;
        if (bytes[2] == 0x4b and bytes[3] == 1) return .connected;
        if (bytes[2] >= 0x80 or bytes[3] & 0x0f != 0) return .ignored;
        return .notification;
    }
    // DJ encapsulated mouse input (report type 0x02), if exposed by the receiver.
    if (bytes[0] == 0x20 or bytes[0] == 0x21) {
        if (bytes.len < 4) return .ignored;
        if (bytes[2] == 0x42) return if (bytes[3] & 1 == 0) .connected else .disconnected;
        return if (bytes[2] == 2) .activity else .ignored;
    }
    return .activity;
}

// Scheduling is independent of hardware and wall-clock changes. A recovery
// burst has at most five attempts, then requires a new wake/activity event.
pub const Recovery = struct {
    reason: enum { startup, settings_changed, activity_after_idle, reconnected, system_resume } = .startup,
    pending: bool = false,
    attempts: u8 = 0,
    due_ms: i64 = 0,
    last_activity_ms: ?i64 = null,
    last_success_ms: ?i64 = null,

    pub fn request(self: *Recovery, now: i64) void {
        if (self.pending) return;
        self.pending = true;
        self.attempts = 0;
        self.due_ms = now;
    }

    pub fn activity(self: *Recovery, now: i64, idle_ms: i64) void {
        const after_idle = if (self.last_activity_ms) |previous| now - previous >= idle_ms else true;
        self.last_activity_ms = now;
        if (after_idle and !self.pending and (self.last_success_ms == null or now - self.last_success_ms.? >= 1000)) {
            self.reason = .activity_after_idle;
            self.request(now);
        }
    }

    pub fn ready(self: Recovery, now: i64) bool {
        return self.pending and now >= self.due_ms;
    }

    pub fn failed(self: *Recovery, now: i64) void {
        self.attempts += 1;
        if (self.attempts >= 5) {
            self.pending = false;
        } else self.due_ms = now + (@as(i64, 1000) << @intCast(self.attempts - 1));
    }

    pub fn succeeded(self: *Recovery, now: i64) void {
        self.pending = false;
        self.attempts = 0;
        self.last_success_ms = now;
        self.last_activity_ms = now;
    }
};

const Node = struct {
    file: std.Io.File,
    path: [128]u8,
    path_len: usize,
};

const Monitor = struct {
    nodes: std.ArrayList(Node) = .empty,
    allocator: std.mem.Allocator,
    io: std.Io,
    online: ?bool = null,

    fn close(self: *Monitor) void {
        for (self.nodes.items) |node| node.file.close(self.io);
        self.nodes.deinit(self.allocator);
    }

    fn scan(self: *Monitor, allocator: std.mem.Allocator, filter: discovery.Filter, explicit_path: ?[]const u8) !bool {
        const candidates = try discovery.scan(self.io, allocator);
        var changed = false;
        var index: usize = 0;
        while (index < self.nodes.items.len) {
            const node = self.nodes.items[index];
            var found = false;
            for (candidates) |candidate| {
                if (!accept(candidate, filter, explicit_path)) continue;
                if (std.mem.eql(u8, candidate.path, node.path[0..node.path_len])) found = true;
            }
            if (!found) {
                node.file.close(self.io);
                _ = self.nodes.swapRemove(index);
                changed = true;
            } else index += 1;
        }
        var permission_denied = false;
        for (candidates) |candidate| {
            if (!accept(candidate, filter, explicit_path)) continue;
            var found = false;
            for (self.nodes.items) |node| {
                if (std.mem.eql(u8, candidate.path, node.path[0..node.path_len])) found = true;
            }
            if (found) continue;
            if (candidate.path.len > 128 or self.nodes.items.len == 32) return error.TooManyDevices;
            const file = std.Io.Dir.openFileAbsolute(self.io, candidate.path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => {
                    permission_denied = true;
                    continue;
                },
                error.FileNotFound, error.NoDevice => continue,
                else => return err,
            };
            errdefer file.close(self.io);
            var node: Node = .{ .file = file, .path = undefined, .path_len = candidate.path.len };
            @memcpy(node.path[0..node.path_len], candidate.path);
            try self.nodes.append(self.allocator, node);
            changed = true;
        }
        if (permission_denied and self.nodes.items.len == 0) return error.PermissionDenied;
        return changed;
    }

    fn accept(candidate: discovery.Candidate, filter: discovery.Filter, explicit_path: ?[]const u8) bool {
        if (explicit_path) |path| return std.mem.eql(u8, path, candidate.path);
        return filter == .auto or std.mem.eql(u8, @tagName(filter), @tagName(candidate.connection));
    }

    fn poll(self: *Monitor, recovery: *Recovery, options: Options, log: *std.Io.Writer) !void {
        var fds: [32]std.posix.pollfd = undefined;
        for (self.nodes.items, 0..) |node, i| fds[i] = .{
            .fd = node.file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        };
        const count = self.nodes.items.len;
        if (try std.posix.poll(fds[0..count], 500) == 0) return;
        // Reverse order allows removing disconnected nodes without invalidating
        // the unprocessed descriptors. Reading does not consume desktop events.
        var i = count;
        while (i > 0) {
            i -= 1;
            if (fds[i].revents == 0) continue;
            if (fds[i].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
                self.nodes.items[i].file.close(self.io);
                _ = self.nodes.swapRemove(i);
                recovery.last_activity_ms = null;
                if (self.nodes.items.len == 0) self.online = false;
                continue;
            }
            var bytes: [64]u8 = undefined;
            const n = std.posix.read(fds[i].fd, &bytes) catch continue;
            const event = classify(bytes[0..n]);
            const now = bootMs(self.io);
            switch (event) {
                .activity => {
                    self.online = true;
                    recovery.activity(now, options.idle_ms);
                },
                .connected => {
                    self.online = true;
                    if (!recovery.pending and (recovery.last_success_ms == null or now - recovery.last_success_ms.? > 1000)) {
                        recovery.reason = .reconnected;
                        recovery.request(now);
                    }
                },
                .disconnected => {
                    self.online = false;
                    recovery.last_activity_ms = null;
                    recovery.pending = false;
                },
                .notification, .ignored => {},
            }
            if (options.trace and event != .activity and event != .ignored) {
                try log.print("px2 watch: {d} {s} {s} {x}\n", .{ now, self.nodes.items[i].path[0..self.nodes.items[i].path_len], @tagName(event), bytes[0..n] });
                try log.flush();
            }
        }
    }
};

fn bootMs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.boot.now(io).toMilliseconds());
}

fn publish(store: state.Store, status: *state.WatchStatus, log: *std.Io.Writer) !void {
    status.updated_at_ms = @intCast(std.Io.Clock.real.now(store.io).toMilliseconds());
    try store.write("watch-status.json", status.*);
    try log.print("px2 watch: {s}{s}{s}\n", .{ @tagName(status.phase), if (status.last_error != null) ": " else "", status.last_error orelse "" });
    if (status.phase == .restoring) try log.print("px2 watch: trigger={s}, profile={d}, revision={d}\n", .{ status.trigger orelse "unknown", status.desired_profile.?, status.desired_revision });
    try log.flush();
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, options: Options, log: *std.Io.Writer) !void {
    const root_store: state.Store = .{ .io = io, .allocator = allocator, .directory = directory };
    const singleton = try root_store.acquire("watch.lock", false);
    defer singleton.close(io);
    var monitor: Monitor = .{ .allocator = allocator, .io = io };
    defer monitor.close();
    var recovery: Recovery = .{};
    var status: state.WatchStatus = .{};
    try publish(root_store, &status, log);
    var previous: ?state.Desired = null;
    var next_scan: i64 = 0;
    var next_state_read: i64 = 0;
    var suspended_ms = bootMs(io) - @as(i64, @intCast(std.Io.Clock.awake.now(io).toMilliseconds()));
    while (true) {
        // Discovery and JSON allocations die every iteration. The CLI's process
        // arena is unsuitable for allocations in this indefinitely running loop.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const store: state.Store = .{ .io = io, .allocator = scratch, .directory = directory };
        const now = bootMs(io);
        const suspend_total = now - @as(i64, @intCast(std.Io.Clock.awake.now(io).toMilliseconds()));
        if (suspend_total - suspended_ms > 500) {
            recovery.reason = .system_resume;
            recovery.request(now);
            next_scan = 0;
        }
        suspended_ms = suspend_total;

        if (now >= next_state_read) {
            next_state_read = now + 1000;
            const desired = store.load() catch |err| {
                if (status.phase != .invalid_state or !std.mem.eql(u8, status.last_error orelse "", @errorName(err))) {
                    status.phase = .invalid_state;
                    status.last_error = @errorName(err);
                    try publish(store, &status, log);
                }
                previous = null;
                recovery.pending = false;
                try std.Io.sleep(io, .fromMilliseconds(500), .awake);
                continue;
            };
            if (previous == null or !std.meta.eql(previous.?, desired)) {
                recovery.reason = if (previous == null) .startup else .settings_changed;
                previous = desired;
                status.desired_revision = desired.revision;
                status.desired_profile = desired.slot();
                status.last_error = null;
                next_scan = 0;
                if (desired.sector != null) {
                    recovery.pending = false;
                    recovery.request(now);
                    status.phase = .waiting_for_device;
                    try publish(store, &status, log);
                } else {
                    recovery.pending = false;
                    status.phase = .waiting_for_profile;
                    try publish(store, &status, log);
                }
            }
        }
        const desired = previous orelse {
            try std.Io.sleep(io, .fromMilliseconds(500), .awake);
            continue;
        };
        if (desired.sector == null) {
            try std.Io.sleep(io, .fromMilliseconds(500), .awake);
            continue;
        }
        if (now >= next_scan) {
            next_scan = now + 3000;
            const changed = monitor.scan(scratch, options.connection orelse desired.connection, options.device_path) catch |err| blk: {
                if (!std.mem.eql(u8, status.last_error orelse "", @errorName(err))) {
                    status.phase = .waiting_for_device;
                    status.last_error = @errorName(err);
                    try publish(store, &status, log);
                }
                break :blk false;
            };
            if (changed and monitor.nodes.items.len > 0 and !recovery.pending) {
                recovery.reason = .reconnected;
                recovery.request(now);
            }
        }
        status.observed_interfaces = monitor.nodes.items.len;
        if (monitor.nodes.items.len == 0) {
            monitor.online = false;
            if (status.phase != .waiting_for_device or status.device_online != false) {
                status.device_online = false;
                status.phase = .waiting_for_device;
                try publish(store, &status, log);
            }
        } else if (recovery.ready(now)) {
            // All px2 commands use this lock, including reads. Reload *under*
            // the lock so a CLI change cannot be overwritten by stale intent.
            const transaction = store.acquire("device.lock", false) catch |err| switch (err) {
                error.AlreadyRunning => {
                    try monitor.poll(&recovery, options, log);
                    continue;
                },
                else => return err,
            };
            defer transaction.close(io);
            const latest = store.load() catch {
                next_state_read = 0;
                continue;
            };
            if (latest.sector == null) continue;
            status.phase = .restoring;
            status.trigger = @tagName(recovery.reason);
            status.desired_revision = latest.revision;
            status.desired_profile = latest.slot();
            try publish(store, &status, log);
            attempt(io, scratch, latest, options) catch |err| {
                recovery.failed(bootMs(io));
                status.attempts = recovery.attempts;
                status.phase = if (recovery.pending) .waiting_for_device else .waiting_for_activity;
                status.last_error = @errorName(err);
                try publish(store, &status, log);
                continue;
            };
            if (!std.meta.eql(previous.?, latest)) next_scan = 0;
            previous = latest;
            recovery.succeeded(bootMs(io));
            monitor.online = true;
            status.device_online = true;
            status.last_restore_ms = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
            status.last_restored_revision = latest.revision;
            status.last_restored_profile = latest.slot();
            status.attempts = 0;
            status.last_error = null;
            status.phase = .monitoring;
            try publish(store, &status, log);
        }
        try monitor.poll(&recovery, options, log);
        if (monitor.online != status.device_online) {
            status.device_online = monitor.online;
            if (monitor.online == false) status.phase = .waiting_for_activity;
            try publish(store, &status, log);
        }
    }
}

fn attempt(io: std.Io, allocator: std.mem.Allocator, desired: state.Desired, options: Options) !void {
    var connected = try discovery.connect(io, allocator, options.connection orelse desired.connection, options.device_path, options.timeout_ms);
    defer connected.close(allocator);
    try restore.apply(io, allocator, .{ .session = &connected.session }, desired);
}

test "idle recovery is passive, coalesces reports, and ignores continuous movement" {
    var recovery: Recovery = .{};
    try std.testing.expect(!recovery.ready(100000));
    recovery.activity(100000, 30000);
    try std.testing.expect(recovery.ready(100000));
    recovery.succeeded(100250);
    recovery.activity(100300, 30000);
    recovery.activity(110000, 30000);
    try std.testing.expect(!recovery.ready(200000));
    recovery.activity(200000, 30000);
    try std.testing.expect(recovery.ready(200000));
}

test "retry bursts are bounded and a new wake can recover after exhaustion" {
    var recovery: Recovery = .{};
    recovery.activity(0, 30000);
    recovery.failed(0);
    recovery.request(10);
    try std.testing.expect(!recovery.ready(999));
    try std.testing.expect(recovery.ready(1000));
    recovery.failed(1000);
    recovery.failed(3000);
    recovery.failed(7000);
    recovery.failed(15000);
    try std.testing.expect(!recovery.ready(100000));
    recovery.activity(100000, 30000);
    try std.testing.expect(recovery.ready(100000));
    try std.testing.expectEqual(@as(u8, 0), recovery.attempts);
}

test "notification decoding distinguishes wake, disconnection and command replies" {
    try std.testing.expectEqual(Event.connected, classify(&.{ 0x10, 1, 0x41, 4, 0x20, 0, 0 }));
    try std.testing.expectEqual(Event.disconnected, classify(&.{ 0x10, 1, 0x41, 4, 0x60, 0, 0 }));
    try std.testing.expectEqual(Event.ignored, classify(&.{ 0x10, 1, 0x0c, 0x1a, 0, 0, 0 }));
    try std.testing.expectEqual(Event.notification, classify(&.{ 0x10, 1, 0x0c, 0x10, 0, 0, 0 }));
    try std.testing.expectEqual(Event.activity, classify(&.{ 2, 0, 1, 0, 0, 0 }));
}
