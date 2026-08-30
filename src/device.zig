const std = @import("std");
const hidpp = @import("hidpp.zig");
const profile = @import("profile.zig");

pub const FeatureId = struct {
    pub const feature_set: u16 = 0x0001;
    pub const device_name: u16 = 0x0005;
    pub const battery: u16 = 0x1004;
    pub const hits: u16 = 0x1b0c;
    pub const dpi: u16 = 0x2202;
    pub const report_rate: u16 = 0x8061;
    pub const onboard_profiles: u16 = 0x8100;
};

pub const Battery = struct {
    percent: u8,
    charging_state: u8,

    pub fn charging(self: Battery) bool {
        return self.charging_state != 0;
    }
};

pub const HitsCapabilities = struct {
    button_count: u8,
    max_actuation: u8,
    max_rapid_trigger: u8,
    max_haptics: u8,
};

pub const HitsConfig = struct {
    button: u8,
    actuation: u8,
    rapid_trigger: u8,
    haptics: u8,
    sensitivity_flag: bool,
};

pub const ProfileInfo = struct {
    memory_model: u8,
    format: u8,
    count: u8,
    button_count: u8,
    sector_size: u16,
};

pub const DpiRange = struct {
    min: u16,
    max: u16,
    step: u16,

    pub fn supports(self: DpiRange, value: u16) bool {
        return value >= self.min and value <= self.max and
            (self.step == 0 or (value - self.min) % self.step == 0);
    }
};

pub const Device = struct {
    session: *hidpp.Session,

    pub fn battery(self: Device) !Battery {
        const index = try self.session.feature(FeatureId.battery);
        const response = try self.session.request(index, 1, &.{});
        if (response.params().len < 3) return error.InvalidFrame;
        return .{ .percent = response.params()[0], .charging_state = response.params()[2] };
    }

    pub fn hitsCapabilities(self: Device) !HitsCapabilities {
        const index = try self.session.feature(FeatureId.hits);
        const response = try self.session.request(index, 0, &.{});
        const p = response.params();
        if (p.len < 5) return error.InvalidFrame;
        return .{
            .button_count = p[1],
            .max_actuation = p[2] >> 2,
            .max_rapid_trigger = p[3] >> 2,
            .max_haptics = p[4] >> 2,
        };
    }

    pub fn hitsConfig(self: Device, button: u8) !HitsConfig {
        const index = try self.session.feature(FeatureId.hits);
        const response = try self.session.request(index, 2, &.{button});
        const p = response.params();
        if (p.len < 4 or p[0] != button) return error.InvalidFrame;
        return .{
            .button = button,
            .actuation = p[1] >> 2,
            .rapid_trigger = p[2] >> 2,
            .haptics = p[3] >> 2,
            .sensitivity_flag = (p[2] & 1) != 0,
        };
    }

    pub fn setHits(self: Device, button: u8, actuation: ?u8, rapid_trigger: ?u8, haptics: ?u8) !HitsConfig {
        const capabilities = try self.hitsCapabilities();
        var current = try self.hitsConfig(button);
        if (actuation) |value| {
            if (value < 1 or value > capabilities.max_actuation) return error.InvalidActuation;
            current.actuation = value;
        }
        if (rapid_trigger) |value| {
            if (value < 1 or value > capabilities.max_rapid_trigger) return error.InvalidRapidTrigger;
            current.rapid_trigger = value;
        }
        if (haptics) |value| {
            if (value > capabilities.max_haptics) return error.InvalidHaptics;
            current.haptics = value;
        }

        const index = try self.session.feature(FeatureId.hits);
        const rapid_wire = (current.rapid_trigger << 2) | @intFromBool(current.sensitivity_flag);
        const response = try self.session.request(index, 1, &.{
            button,
            current.actuation << 2,
            rapid_wire,
            current.haptics << 2,
        });
        if (response.params().len < 4) return error.InvalidFrame;
        return try self.hitsConfig(button);
    }

    pub fn currentDpi(self: Device) !struct { x: u16, y: u16, lod: u8 } {
        const index = try self.session.feature(FeatureId.dpi);
        const response = try self.session.request(index, 5, &.{0});
        const p = response.params();
        if (p.len < 3) return error.InvalidFrame;
        const x = readBe16(p[1..][0..2]);
        const reported_y = if (p.len >= 7) readBe16(p[5..][0..2]) else 0;
        return .{
            .x = x,
            .y = if (reported_y == 0) x else reported_y,
            .lod = if (p.len >= 10) p[9] else 0,
        };
    }

    pub fn dpiRange(self: Device) !DpiRange {
        const index = try self.session.feature(FeatureId.dpi);
        var result: DpiRange = .{ .min = std.math.maxInt(u16), .max = 0, .step = 1 };
        var pending_range_max = false;
        for (0..32) |page| {
            const response = try self.session.request(index, 2, &.{ 0, 0, @intCast(page) });
            const p = response.params();
            if (p.len < 5) return error.InvalidFrame;
            var offset: usize = 3;
            while (offset + 1 < p.len) : (offset += 2) {
                const value = readBe16(p[offset..][0..2]);
                if (value == 0) {
                    if (result.min == std.math.maxInt(u16) or result.max < result.min)
                        return error.InvalidFrame;
                    return result;
                }
                if (pending_range_max) {
                    result.max = @max(result.max, value);
                    pending_range_max = false;
                } else if ((value >> 13) == 0b111) {
                    result.step = value & 0x1fff;
                    pending_range_max = true;
                } else {
                    result.min = @min(result.min, value);
                    result.max = @max(result.max, value);
                }
            }
        }
        return error.InvalidFrame;
    }

    pub fn supportedRateMask(self: Device) !u16 {
        const index = try self.session.feature(FeatureId.report_rate);
        const response = try self.session.request(index, 1, &.{});
        if (response.params().len < 2) return error.InvalidFrame;
        return readBe16(response.params()[0..2]);
    }

    pub fn currentRate(self: Device) !u16 {
        const index = try self.session.feature(FeatureId.report_rate);
        const response = try self.session.request(index, 2, &.{});
        if (response.params().len < 1 or response.params()[0] > 6) return error.InvalidFrame;
        return @as(u16, 125) << @intCast(response.params()[0]);
    }

    pub fn profileInfo(self: Device) !ProfileInfo {
        const index = try self.session.feature(FeatureId.onboard_profiles);
        const response = try self.session.request(index, 0, &.{});
        const p = response.params();
        if (p.len < 9) return error.InvalidFrame;
        return .{
            .memory_model = p[0],
            .format = p[1],
            .count = p[3],
            .button_count = p[5],
            .sector_size = readBe16(p[7..][0..2]),
        };
    }

    pub fn currentProfile(self: Device) !u16 {
        const index = try self.session.feature(FeatureId.onboard_profiles);
        const response = try self.session.request(index, 4, &.{});
        if (response.params().len < 2) return error.InvalidFrame;
        return readBe16(response.params()[0..2]);
    }

    pub fn activateProfile(self: Device, sector: u16) !void {
        const index = try self.session.feature(FeatureId.onboard_profiles);
        _ = try self.session.request(index, 3, &.{ @intCast(sector >> 8), @intCast(sector & 0xff) });
    }

    pub fn readSector(self: Device, allocator: std.mem.Allocator, sector: u16) ![]u8 {
        const info = try self.profileInfo();
        if (info.sector_size < 16 or info.sector_size > 4096) return error.UnsupportedLayout;
        const bytes = try allocator.alloc(u8, info.sector_size);
        errdefer allocator.free(bytes);
        const index = try self.session.feature(FeatureId.onboard_profiles);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const read_offset = if (bytes.len - offset < 16) bytes.len - 16 else offset;
            const response = try self.session.request(index, 5, &.{
                @intCast(sector >> 8),
                @intCast(sector & 0xff),
                @intCast(read_offset >> 8),
                @intCast(read_offset & 0xff),
            });
            if (response.params().len < 16) return error.InvalidFrame;
            @memcpy(bytes[read_offset..][0..16], response.params()[0..16]);
            if (read_offset + 16 == bytes.len) break;
            offset += 16;
        }
        return bytes;
    }

    /// Writes only the known, CRC-validated Superstrike profile format and
    /// verifies the committed bytes by reading them back.
    pub fn writeSector(self: Device, allocator: std.mem.Allocator, sector: u16, bytes: []const u8) !void {
        if (sector == 0 or sector > 5) return error.RefusingUnsafeSector;
        try profile.validate(bytes);
        const info = try self.profileInfo();
        if (info.sector_size != profile.sector_size or bytes.len != info.sector_size)
            return error.UnsupportedLayout;

        const index = try self.session.feature(FeatureId.onboard_profiles);
        _ = try self.session.request(index, 6, &.{
            @intCast(sector >> 8),    @intCast(sector & 0xff),    0, 0,
            @intCast(bytes.len >> 8), @intCast(bytes.len & 0xff),
        });

        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 16) {
            var chunk: [16]u8 = @splat(0);
            const count = @min(16, bytes.len - offset);
            @memcpy(chunk[0..count], bytes[offset..][0..count]);
            _ = try self.session.request(index, 7, &chunk);
        }
        _ = try self.session.request(index, 8, &.{});

        const actual = try self.readSector(allocator, sector);
        defer allocator.free(actual);
        if (!std.mem.eql(u8, bytes, actual)) return error.VerificationFailed;
    }

    pub fn featureTable(self: Device, allocator: std.mem.Allocator) ![]u16 {
        const index = try self.session.feature(FeatureId.feature_set);
        const count_response = try self.session.request(index, 0, &.{});
        if (count_response.params().len == 0) return error.InvalidFrame;
        const count = count_response.params()[0];
        const result = try allocator.alloc(u16, count);
        errdefer allocator.free(result);
        for (result, 0..) |*item, i| {
            const response = try self.session.request(index, 1, &.{@intCast(i)});
            if (response.params().len < 2) return error.InvalidFrame;
            item.* = readBe16(response.params()[0..2]);
        }
        return result;
    }
};

fn readBe16(bytes: *const [2]u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}
