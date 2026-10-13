const std = @import("std");
pub const max_output = 1024 * 1024;
pub const Hits = struct { actuation: ?u8 = null, rapid_trigger: ?u8 = null, haptics: ?u8 = null };
pub const Profile = struct {
    slot: u8,
    initialized: bool = false,
    editable: bool = false,
    editable_reason: ?[]const u8 = null,
    crc_valid: bool = false,
    rom_health: []const u8 = "unknown",
    dpi_x: u16 = 0,
    dpi_y: u16 = 0,
    rate_hz: u16 = 0,
};
pub const DpiRange = struct {
    min: u16 = 0,
    max: u16 = 0,
    step: u16 = 0,
    pub fn supports(self: DpiRange, value: u16) bool {
        return self.min >= 100 and self.max <= 44000 and value >= self.min and value <= self.max and
            (self.step == 0 or (value - self.min) % self.step == 0);
    }
};
pub const Capabilities = struct { button_count: u8 = 0, max_actuation: u8 = 0, max_rapid_trigger: u8 = 0, max_haptics: u8 = 0 };
pub const Values = struct { dpi_x: u16 = 0, dpi_y: u16 = 0, rate_hz: u16 = 0 };
pub const Snapshot = struct {
    schema_version: u8,
    device: struct { name: []const u8 = "PRO X2 SUPERSTRIKE", connection: []const u8 = "unknown", path: []const u8 = "" },
    battery: struct { percent: ?u8 = null, charging: bool = false } = .{},
    active_profile: u8,
    desired_profile: ?u8 = null,
    saved: Values = .{},
    reported: Values = .{},
    supported: struct { dpi: DpiRange = .{}, rates_hz: []const u16 = &.{} } = .{},
    hits: struct { capabilities: Capabilities = .{}, left: Hits = .{}, right: Hits = .{} } = .{},
    profiles: []const Profile,
    pub fn profile(self: Snapshot, slot: u8) ?Profile {
        for (self.profiles) |p| if (p.slot == slot) return p;
        return null;
    }
    pub fn validate(self: Snapshot) !void {
        if (self.profiles.len == 0 or self.profiles.len > 8) return error.InvalidProfiles;
        var slots: u16 = 0;
        for (self.profiles) |p| {
            if (p.slot < 1 or p.slot > 8) return error.InvalidProfiles;
            const mask = @as(u16, 1) << @intCast(p.slot);
            if (slots & mask != 0) return error.InvalidProfiles;
            slots |= mask;
        }
        if (self.profile(self.active_profile) == null) return error.InvalidProfiles;
    }
};
pub const Watch = struct {
    schema_version: u8,
    running: bool,
    state_directory: []const u8 = "",
    state_error: ?[]const u8 = null,
    desired: struct {
        revision: u64 = 0,
        sector: ?u16 = null,
        connection: []const u8 = "auto",
        hits: [8][2]Hits = @splat(@splat(.{})),
    } = .{},
    last_status: ?struct {
        phase: []const u8 = "unknown",
        last_restore_ms: ?i64 = null,
        last_error: ?[]const u8 = null,
        restoration_verified: bool = false,
    } = null,
};
pub const Reply = struct {
    schema_version: u8,
    ok: bool = false,
    @"error": ?[]const u8 = null,
    backup_dir: ?[]const u8 = null,
    backup: ?struct { path: []const u8 = "", created: bool = false } = null,
};
pub fn parse(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    if (bytes.len > max_output) return error.OutputTooLarge;
    var result = try std.json.parseFromSlice(T, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer result.deinit();
    if (result.value.schema_version != 1) return error.UnsupportedSchema;
    if (T == Snapshot) try result.value.validate();
    return result;
}

test "reject incompatible schema and malformed JSON" {
    try std.testing.expectError(error.UnsupportedSchema, parse(Reply, std.testing.allocator, "{\"schema_version\":2,\"ok\":true}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, parse(Reply, std.testing.allocator, "{"));
    var value = try parse(Reply, std.testing.allocator, "{\"schema_version\":1,\"ok\":true,\"future\":42}");
    defer value.deinit();
    try std.testing.expect(value.value.ok);
}
