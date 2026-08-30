const std = @import("std");
const HidRaw = @import("linux/hidraw.zig").HidRaw;
const hidpp = @import("hidpp.zig");

pub const Connection = enum {
    direct,
    receiver,
    unknown,
};

pub const Filter = enum {
    auto,
    direct,
    receiver,
};

pub const Candidate = struct {
    path: []const u8,
    name: []const u8,
    vid: u16,
    pid: u16,
    connection: Connection,
};

pub const Connected = struct {
    raw: *HidRaw,
    session: hidpp.Session,
    candidate: Candidate,

    pub fn close(self: *Connected, allocator: std.mem.Allocator) void {
        self.raw.close();
        allocator.destroy(self.raw);
    }
};

pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]Candidate {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/hidraw", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Candidate, 0),
        else => return err,
    };
    defer dir.close(io);

    var candidates: std.ArrayList(Candidate) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "hidraw")) continue;
        const sys_path = try std.fmt.allocPrint(allocator, "/sys/class/hidraw/{s}/device/uevent", .{entry.name});
        const text = std.Io.Dir.cwd().readFileAlloc(io, sys_path, allocator, .limited(16 * 1024)) catch continue;
        const id = parseHidId(text) orelse continue;
        if (id.vid != 0x046d) continue;

        const connection: Connection = switch (id.pid) {
            0xc0a8 => .direct,
            0xc54d, 0x40bd => .receiver,
            else => continue,
        };
        const name = try allocator.dupe(u8, parseValue(text, "HID_NAME=") orelse "Logitech HID++ device");
        const path = try std.fmt.allocPrint(allocator, "/dev/{s}", .{entry.name});
        try candidates.append(allocator, .{
            .path = path,
            .name = name,
            .vid = id.vid,
            .pid = id.pid,
            .connection = connection,
        });
    }
    return candidates.toOwnedSlice(allocator);
}

pub fn connect(
    io: std.Io,
    allocator: std.mem.Allocator,
    filter: Filter,
    explicit_path: ?[]const u8,
    timeout_ms: u32,
) !Connected {
    if (explicit_path) |path| {
        const candidate: Candidate = .{
            .path = try allocator.dupe(u8, path),
            .name = "explicit hidraw device",
            .vid = 0x046d,
            .pid = 0,
            .connection = .unknown,
        };
        return try connectCandidate(io, allocator, candidate, filter, timeout_ms);
    }

    const candidates = try scan(io, allocator);
    var saw_permission_denied = false;
    for (candidates) |candidate| {
        if (!matches(filter, candidate.connection)) continue;
        return connectCandidate(io, allocator, candidate, filter, timeout_ms) catch |err| switch (err) {
            error.PermissionDenied => {
                saw_permission_denied = true;
                continue;
            },
            error.Unsupported => continue,
            else => return err,
        };
    }
    if (saw_permission_denied) return error.PermissionDenied;
    return error.DeviceNotFound;
}

fn connectCandidate(io: std.Io, allocator: std.mem.Allocator, candidate: Candidate, filter: Filter, timeout_ms: u32) !Connected {
    const raw = try allocator.create(HidRaw);
    errdefer allocator.destroy(raw);
    raw.* = try HidRaw.open(io, candidate.path);
    errdefer raw.close();

    const direct_indexes = [_]u8{0xff};
    const receiver_indexes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const all_indexes = [_]u8{ 0xff, 1, 2, 3, 4, 5, 6 };
    const indexes: []const u8 = switch (filter) {
        .direct => &direct_indexes,
        .receiver => &receiver_indexes,
        .auto => switch (candidate.connection) {
            .direct => &direct_indexes,
            .receiver => &receiver_indexes,
            .unknown => &all_indexes,
        },
    };

    for (indexes) |index| {
        var session: hidpp.Session = .{
            .transport = raw.transport(),
            .device_index = index,
            .timeout_ms = timeout_ms,
        };
        _ = session.feature(0x1b0c) catch continue;
        return .{ .raw = raw, .session = session, .candidate = candidate };
    }
    return error.Unsupported;
}

fn matches(filter: Filter, connection: Connection) bool {
    return switch (filter) {
        .auto => true,
        .direct => connection == .direct,
        .receiver => connection == .receiver,
    };
}

fn parseHidId(text: []const u8) ?struct { vid: u16, pid: u16 } {
    const value = parseValue(text, "HID_ID=") orelse return null;
    var parts = std.mem.splitScalar(u8, value, ':');
    _ = parts.next() orelse return null;
    const vid_text = parts.next() orelse return null;
    const pid_text = parts.next() orelse return null;
    return .{
        .vid = std.fmt.parseInt(u16, vid_text, 16) catch return null,
        .pid = std.fmt.parseInt(u16, pid_text, 16) catch return null,
    };
}

fn parseValue(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    return null;
}

test "parse sysfs HID identity" {
    const text = "DRIVER=hid-generic\nHID_ID=0003:0000046D:000040BD\nHID_NAME=Logitech X2 SUPERSTRIKE\n";
    const id = parseHidId(text).?;
    try std.testing.expectEqual(@as(u16, 0x046d), id.vid);
    try std.testing.expectEqual(@as(u16, 0x40bd), id.pid);
    try std.testing.expectEqualStrings("Logitech X2 SUPERSTRIKE", parseValue(text, "HID_NAME=").?);
}
