const std = @import("std");
const discovery = @import("discovery.zig");

pub const Hits = struct {
    actuation: ?u8 = null,
    rapid_trigger: ?u8 = null,
    haptics: ?u8 = null,
};

pub const Desired = struct {
    schema_version: u8 = 1,
    revision: u64 = 0,
    sector: ?u16 = null,
    connection: discovery.Filter = .auto,
    hits: [8][2]Hits = @splat(@splat(.{})),

    pub fn slot(self: Desired) ?u8 {
        return if (self.sector) |s| @intCast(s & 0xff) else null;
    }

    pub fn validate(self: Desired) !void {
        if (self.schema_version != 1) return error.UnsupportedStateVersion;
        if (self.sector) |s| {
            if (s >> 8 > 1 or s & 0xff < 1 or s & 0xff > 8) return error.InvalidState;
        }
        for (self.hits) |buttons| for (buttons) |button| {
            if (button.actuation) |v| if (v == 0 or v > 63) return error.InvalidState;
            if (button.rapid_trigger) |v| if (v == 0 or v > 63) return error.InvalidState;
            if (button.haptics) |v| if (v > 63) return error.InvalidState;
        };
    }
};

pub const WatchStatus = struct {
    schema_version: u8 = 1,
    phase: enum { waiting_for_profile, waiting_for_device, restoring, monitoring, waiting_for_activity, invalid_state } = .waiting_for_profile,
    desired_revision: u64 = 0,
    desired_profile: ?u8 = null,
    last_restore_ms: ?i64 = null,
    last_restored_revision: ?u64 = null,
    last_restored_profile: ?u8 = null,
    trigger: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
    attempts: u8 = 0,
    device_online: ?bool = null,
    observed_interfaces: usize = 0,
    // A successful HID++ transaction is not proof that stale firmware getters
    // reflect the physical settings. Do not label these values "effective".
    restoration_verified: bool = false,
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,

    pub fn load(self: Store) !Desired {
        return (try self.read(Desired, "desired.json")) orelse .{};
    }

    pub fn save(self: Store, desired: *Desired) !void {
        try desired.validate();
        desired.revision = try std.math.add(u64, desired.revision, 1);
        try self.write("desired.json", desired.*);
    }

    pub fn read(self: Store, comptime T: type, name: []const u8) !?T {
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, name });
        defer self.allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(bytes);
        // String fields belong to the caller's operation-scoped arena.
        const value = try std.json.parseFromSliceLeaky(T, self.allocator, bytes, .{ .allocate = .alloc_always });
        if (T == Desired) try value.validate();
        return value;
    }

    pub fn write(self: Store, name: []const u8, value: anytype) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.directory);
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, name });
        defer self.allocator.free(path);
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .replace = true, .permissions = .fromMode(0o600) });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    // Lock files must never be unlinked: all processes must lock the same inode.
    pub fn acquire(self: Store, name: []const u8, wait: bool) !std.Io.File {
        try std.Io.Dir.cwd().createDirPath(self.io, self.directory);
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, name });
        defer self.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
        errdefer file.close(self.io);
        if (wait) {
            try file.lock(self.io, .exclusive);
        } else if (!try file.tryLock(self.io, .exclusive)) return error.AlreadyRunning;
        return file;
    }
};

test "desired state validates sector banks, version and HITS without inferring defaults" {
    var desired: Desired = .{};
    try desired.validate();
    try std.testing.expectEqual(null, desired.slot());
    try std.testing.expectEqual(null, desired.hits[0][0].haptics);
    desired.sector = 0x0105;
    try desired.validate();
    try std.testing.expectEqual(@as(?u8, 5), desired.slot());
    desired.sector = 0x0201;
    try std.testing.expectError(error.InvalidState, desired.validate());
    desired.sector = 1;
    desired.hits[0][1].rapid_trigger = 0;
    try std.testing.expectError(error.InvalidState, desired.validate());
    desired.schema_version = 2;
    try std.testing.expectError(error.UnsupportedStateVersion, desired.validate());
}

test "state round trips, locks serialize clients, and corruption never resets desired state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const directory = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const store: Store = .{ .io = std.testing.io, .allocator = allocator, .directory = directory };
    var desired = try store.load();
    desired.sector = 3;
    desired.hits[2][1].haptics = 0;
    const lock = try store.acquire("device.lock", false);
    try std.testing.expectError(error.AlreadyRunning, store.acquire("device.lock", false));
    try store.save(&desired);
    lock.close(std.testing.io);
    const next_lock = try store.acquire("device.lock", false);
    defer next_lock.close(std.testing.io);
    try std.testing.expect(std.meta.eql(desired, try store.load()));
    desired.sector = 5;
    try store.save(&desired);
    try std.testing.expectEqual(@as(u64, 2), (try store.load()).revision);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "desired.json", .data = "{invalid json" });
    try std.testing.expectError(error.SyntaxError, store.load());
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "desired.json", allocator, .limited(100));
    try std.testing.expectEqualStrings("{invalid json", bytes);
}
