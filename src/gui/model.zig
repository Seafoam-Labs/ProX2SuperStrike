const std = @import("std");
pub const protocol = @import("protocol.zig");
pub const Page = enum { sensitivity, hits, restoration, diagnostics };
pub const Draft = struct {
    dpi: u16 = 0,
    rate: u16 = 0,
    hits: [2]protocol.Hits = @splat(.{}),
    pub fn from(snapshot: protocol.Snapshot, slot: u8) Draft {
        const p = snapshot.profile(slot) orelse return .{};
        return .{ .dpi = p.dpi_x, .rate = p.rate_hz, .hits = if (snapshot.active_profile == slot) .{ snapshot.hits.left, snapshot.hits.right } else @splat(.{}) };
    }
};
pub const Dirty = struct {
    dpi: bool = false,
    rate: bool = false,
    hits: [2][3]bool = @splat(@splat(false)),
    pub fn count(self: Dirty) usize {
        var n: usize = @intFromBool(self.dpi) + @as(usize, @intFromBool(self.rate));
        for (self.hits) |button| for (button) |value| {
            n += @intFromBool(value);
        };
        return n;
    }
};
pub const hit_names = [_][]const u8{ "actuation", "rapid_trigger", "haptics" };
pub fn dirty(base: Draft, draft: Draft) Dirty {
    var result: Dirty = .{ .dpi = base.dpi != draft.dpi, .rate = base.rate != draft.rate };
    for (0..2) |b| inline for (hit_names, 0..) |name, i| {
        result.hits[b][i] = @field(base.hits[b], name) != @field(draft.hits[b], name);
    };
    return result;
}
pub fn merge(new_base: Draft, old_draft: Draft, changed: Dirty) Draft {
    var result = new_base;
    if (changed.dpi) result.dpi = old_draft.dpi;
    if (changed.rate) result.rate = old_draft.rate;
    for (0..2) |b| inline for (hit_names, 0..) |name, i| {
        if (changed.hits[b][i]) @field(result.hits[b], name) = @field(old_draft.hits[b], name);
    };
    return result;
}
pub fn valid(snapshot: protocol.Snapshot, slot: u8, base: Draft, draft: Draft) bool {
    const p = snapshot.profile(slot) orelse return false;
    const changes = dirty(base, draft);
    if ((changes.dpi or changes.rate) and (!p.editable or !p.crc_valid)) return false;
    if (changes.dpi and !snapshot.supported.dpi.supports(draft.dpi)) return false;
    if (changes.rate and std.mem.indexOfScalar(u16, snapshot.supported.rates_hz, draft.rate) == null) return false;
    const caps = snapshot.hits.capabilities;
    for (0..2) |b| inline for (hit_names, 0..) |name, i| {
        if (changes.hits[b][i]) {
            if (snapshot.active_profile != slot or !p.crc_valid or b >= caps.button_count) return false;
            const value = @field(draft.hits[b], name) orelse return false;
            const max = switch (i) {
                0 => caps.max_actuation,
                1 => caps.max_rapid_trigger,
                2 => caps.max_haptics,
                else => unreachable,
            };
            if (max > 63 or value > max or (i != 2 and value == 0)) return false;
        }
    };
    return true;
}
pub const Command = union(enum) {
    snapshot,
    watch,
    doctor,
    dpi: struct { slot: u8, value: u16 },
    rate: struct { slot: u8, value: u16 },
    hits: struct { slot: u8, button: u8, values: protocol.Hits },
    activate: u8,
    initialize: struct { slot: u8, dry_run: bool },
    pub fn writes(self: Command) bool {
        return switch (self) {
            .snapshot, .watch, .doctor => false,
            .initialize => |i| !i.dry_run,
            else => true,
        };
    }
    pub fn args(self: Command, a: std.mem.Allocator) ![]const []const u8 {
        const fmt = struct {
            fn num(alloc: std.mem.Allocator, v: anytype) ![]const u8 {
                return std.fmt.allocPrint(alloc, "{d}", .{v});
            }
        }.num;
        var list: std.ArrayList([]const u8) = .empty;
        switch (self) {
            .snapshot => try list.append(a, "snapshot"),
            .watch => try list.appendSlice(a, &.{ "watch", "status" }),
            .doctor => try list.append(a, "doctor"),
            .dpi => |v| try list.appendSlice(a, &.{ "set", "dpi", try fmt(a, v.value), "--profile", try fmt(a, v.slot) }),
            .rate => |v| try list.appendSlice(a, &.{ "set", "rate", try fmt(a, v.value), "--profile", try fmt(a, v.slot) }),
            .activate => |slot| try list.appendSlice(a, &.{ "profile", "activate", try fmt(a, slot) }),
            .initialize => |v| {
                try list.appendSlice(a, &.{ "profile", "initialize", try fmt(a, v.slot), "--from-factory" });
                if (v.dry_run) try list.append(a, "--dry-run");
            },
            .hits => |v| {
                try list.appendSlice(a, &.{ "set", "hits", if (v.button == 0) "left" else "right", "--profile", try fmt(a, v.slot) });
                inline for (hit_names, .{ "--actuation", "--rapid", "--haptics" }) |name, flag| if (@field(v.values, name)) |value| try list.appendSlice(a, &.{ flag, try fmt(a, value) });
            },
        }
        return list.toOwnedSlice(a);
    }
};
pub const Queue = struct {
    items: [4]Command = undefined,
    len: usize = 0,
    pub fn build(slot: u8, base: Draft, draft: Draft) Queue {
        var self: Queue = .{};
        const changes = dirty(base, draft);
        if (changes.dpi) self.add(.{ .dpi = .{ .slot = slot, .value = draft.dpi } });
        if (changes.rate) self.add(.{ .rate = .{ .slot = slot, .value = draft.rate } });
        for (0..2) |b| {
            var values: protocol.Hits = .{};
            var any = false;
            inline for (hit_names, 0..) |name, i| if (changes.hits[b][i]) {
                @field(values, name) = @field(draft.hits[b], name);
                any = true;
            };
            if (any) self.add(.{ .hits = .{ .slot = slot, .button = @intCast(b), .values = values } });
        }
        return self;
    }
    pub fn add(self: *Queue, command: Command) void {
        self.items[self.len] = command;
        self.len += 1;
    }
};

test "partial reconciliation preserves failed fields, drops completed values, and adopts external untouched values" {
    const base: Draft = .{ .dpi = 800, .rate = 1000 };
    var edited = base;
    edited.dpi = 1600;
    edited.rate = 2000;
    const readback: Draft = .{ .dpi = 1600, .rate = 1000, .hits = .{ .{ .haptics = 2 }, .{} } };
    const result = merge(readback, edited, dirty(base, edited));
    try std.testing.expectEqual(@as(usize, 1), dirty(readback, result).count());
    try std.testing.expectEqual(@as(u16, 2000), result.rate);
    try std.testing.expectEqual(@as(?u8, 2), result.hits[0].haptics);
}
test "HITS commands submit only changed fields, retain zero and specify target profile" {
    const base: Draft = .{ .hits = .{ .{ .actuation = 3, .haptics = 4 }, .{} } };
    var edited = base;
    edited.hits[0].haptics = 0;
    const queue = Queue.build(3, base, edited);
    try std.testing.expectEqual(@as(usize, 1), queue.len);
    try std.testing.expectEqual(@as(?u8, null), queue.items[0].hits.values.actuation);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try queue.items[0].args(arena.allocator());
    try std.testing.expectEqualStrings("--profile", args[3]);
    try std.testing.expectEqualStrings("3", args[4]);
    try std.testing.expectEqualStrings("--haptics", args[5]);
    try std.testing.expectEqualStrings("0", args[6]);
}
test "DPI capability step is relative to minimum and unavailable ranges are blocked" {
    try std.testing.expect((protocol.DpiRange{ .min = 100, .max = 1000, .step = 150 }).supports(250));
    try std.testing.expect(!(protocol.DpiRange{ .min = 100, .max = 1000, .step = 150 }).supports(300));
    try std.testing.expect(!(protocol.DpiRange{}).supports(0));
}
test {
    _ = protocol;
}

test "profile capability gates and active HITS are enforced before queue construction" {
    const profiles = [_]protocol.Profile{
        .{ .slot = 1, .editable = true, .crc_valid = true, .dpi_x = 1600, .dpi_y = 1600, .rate_hz = 1000 },
        .{ .slot = 2, .editable = true, .crc_valid = true, .dpi_x = 1600, .dpi_y = 1600, .rate_hz = 1000 },
        .{ .slot = 5, .editable = false, .crc_valid = true, .dpi_x = 1600, .dpi_y = 1600, .rate_hz = 1000 },
    };
    const snapshot: protocol.Snapshot = .{
        .schema_version = 1,
        .device = .{},
        .active_profile = 1,
        .profiles = &profiles,
        .supported = .{ .dpi = .{ .min = 100, .max = 44000, .step = 50 }, .rates_hz = &.{ 1000, 2000 } },
        .hits = .{ .capabilities = .{ .button_count = 2, .max_actuation = 10, .max_rapid_trigger = 5, .max_haptics = 5 }, .left = .{ .actuation = 3, .haptics = 4 } },
    };
    const base = Draft.from(snapshot, 1);
    var draft = base;
    draft.dpi = 123;
    try std.testing.expect(!valid(snapshot, 1, base, draft));
    draft.dpi = 2400;
    try std.testing.expect(valid(snapshot, 2, base, draft));
    try std.testing.expect(!valid(snapshot, 5, base, draft));
    draft.rate = 8000;
    try std.testing.expect(!valid(snapshot, 1, base, draft));
    draft = base;
    draft.hits[0].haptics = 0;
    try std.testing.expect(valid(snapshot, 1, base, draft));
    try std.testing.expect(!valid(snapshot, 2, base, draft));
    draft.hits[0].haptics = 6;
    try std.testing.expect(!valid(snapshot, 1, base, draft));
}
test "corrupt profile is never editable even with a contradictory editable flag" {
    const profiles = [_]protocol.Profile{.{ .slot = 1, .editable = true, .crc_valid = false }};
    const snapshot: protocol.Snapshot = .{ .schema_version = 1, .device = .{}, .active_profile = 1, .profiles = &profiles };
    try std.testing.expect(!valid(snapshot, 1, .{}, .{ .dpi = 1600 }));
}
