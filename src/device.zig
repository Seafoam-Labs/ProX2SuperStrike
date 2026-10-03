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

pub const SectorInspection = struct {
    bytes: []u8,
    attempts: u8,
    health: profile.SectorHealth,
    stored_crc: u16,
    computed_crc: u16,
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

    /// Matches Solaar's ExtendedAdjustableDpi write: sensor index, big-endian
    /// X/Y values, then the current lift-off-distance value.
    pub fn setCurrentDpi(self: Device, value: u16) !void {
        return self.setCurrentDpiXY(value, value);
    }

    pub fn setCurrentDpiXY(self: Device, x: u16, y: u16) !void {
        const current = try self.currentDpi();
        const index = try self.session.feature(FeatureId.dpi);
        _ = try self.session.request(index, 6, &.{
            0,
            @intCast(x >> 8),
            @intCast(x & 0xff),
            @intCast(y >> 8),
            @intCast(y & 0xff),
            current.lod,
        });
    }

    pub fn dpiRange(self: Device) !DpiRange {
        const index = try self.session.feature(FeatureId.dpi);
        var result: DpiRange = .{ .min = 0, .max = 0, .step = 0 };
        var pending_range_max = false;
        for (0..32) |page| {
            const response = self.session.request(index, 2, &.{ 0, 0, @intCast(page) }) catch break;
            const p = response.params();
            if (p.len < 5) break;
            var offset: usize = 3;
            while (offset + 1 < p.len) : (offset += 2) {
                const value = readBe16(p[offset..][0..2]);
                if (value == 0) return normalizeDpiRange(result);
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
        return normalizeDpiRange(result);
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

    pub fn setCurrentRate(self: Device, hz: u16) !void {
        const rate_index = try profile.rateIndex(hz);
        const index = try self.session.feature(FeatureId.report_rate);
        _ = try self.session.request(index, 3, &.{rate_index});
    }

    pub fn profileInfo(self: Device) !ProfileInfo {
        const index = try self.session.feature(FeatureId.onboard_profiles);
        for (0..8) |_| {
            const response = try self.session.request(index, 0, &.{});
            const p = response.params();
            if (p.len < 9) continue;
            const info: ProfileInfo = .{
                .memory_model = p[0],
                .format = p[1],
                .count = p[3],
                .button_count = p[5],
                .sector_size = readBe16(p[7..][0..2]),
            };
            if (info.memory_model == 1 and info.count >= 1 and info.count <= 8 and
                info.sector_size >= 16 and info.sector_size <= 4096) return info;
        }
        return error.InvalidProfileInfo;
    }

    pub fn currentProfile(self: Device) !u16 {
        const index = try self.session.feature(FeatureId.onboard_profiles);
        const response = try self.session.request(index, 4, &.{});
        if (response.params().len < 2) return error.InvalidFrame;
        return readBe16(response.params()[0..2]);
    }

    pub fn onboardMode(self: Device) !u8 {
        const index = try self.session.feature(FeatureId.onboard_profiles);
        const response = try self.session.request(index, 2, &.{});
        if (response.params().len < 1) return error.InvalidFrame;
        return response.params()[0];
    }

    pub fn setOnboardMode(self: Device, mode: u8) !void {
        if (mode != 1 and mode != 2) return error.InvalidArgument;
        const index = try self.session.feature(FeatureId.onboard_profiles);
        _ = try self.session.request(index, 1, &.{mode});
    }

    pub fn activateProfile(self: Device, sector: u16) !void {
        try self.setOnboardMode(1);
        const index = try self.session.feature(FeatureId.onboard_profiles);
        _ = try self.session.request(index, 3, &.{ @intCast(sector >> 8), @intCast(sector & 0xff) });
    }

    /// Reapplies settings after an in-place profile write. Selecting the
    /// already-current sector is a firmware no-op, so bounce through another
    /// initialized sector (or host mode) before selecting the target again.
    pub fn reloadProfile(self: Device, io: std.Io, target: u16, fallback: u16) !void {
        try self.setOnboardMode(1);
        if (fallback != target) {
            self.activateProfile(fallback) catch |err| switch (err) {
                error.InvalidArgument, error.OutOfRange => {
                    try self.setOnboardMode(2);
                    try std.Io.sleep(io, .fromMilliseconds(120), .awake);
                    try self.setOnboardMode(1);
                },
                else => return err,
            };
            try std.Io.sleep(io, .fromMilliseconds(120), .awake);
        }
        try self.activateProfile(target);
        try std.Io.sleep(io, .fromMilliseconds(120), .awake);
        if (try self.currentProfile() != target) return error.ProfileReloadFailed;
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

    pub fn inspectSector(self: Device, allocator: std.mem.Allocator, sector: u16) !SectorInspection {
        var attempt: u8 = 1;
        while (attempt <= 3) : (attempt += 1) {
            const bytes = try self.readSector(allocator, sector);
            const sector_health = profile.health(bytes);
            const result: SectorInspection = .{
                .bytes = bytes,
                .attempts = attempt,
                .health = sector_health,
                .stored_crc = profile.storedCrc(bytes) catch 0,
                .computed_crc = if (bytes.len >= 2) profile.crc16CcittFalse(bytes[0 .. bytes.len - 2]) else 0,
            };
            if (sector_health == .valid or attempt == 3) return result;
            allocator.free(bytes);
        }
        unreachable;
    }

    pub fn readSectorValidated(self: Device, allocator: std.mem.Allocator, sector: u16) ![]u8 {
        const inspected = try self.inspectSector(allocator, sector);
        switch (inspected.health) {
            .valid => return inspected.bytes,
            .blank => {
                allocator.free(inspected.bytes);
                return error.BlankSector;
            },
            .invalid_crc => {
                allocator.free(inspected.bytes);
                return error.InvalidCrc;
            },
        }
    }

    /// Writes only the known, CRC-validated Superstrike profile format and
    /// verifies the committed bytes by reading them back.
    pub fn writeSector(self: Device, allocator: std.mem.Allocator, sector: u16, bytes: []const u8) !void {
        if (sector == 0 or sector > 5) return error.RefusingUnsafeSector;
        try profile.validate(bytes);
        return self.writeValidatedSector(allocator, sector, bytes);
    }

    pub fn writeControlSector(self: Device, allocator: std.mem.Allocator, bytes: []const u8) !void {
        const info = try self.profileInfo();
        try profile.validate(bytes);
        var entries: [8]profile.ControlEntry = undefined;
        _ = try profile.parseControl(bytes, info.count, &entries);
        return self.writeValidatedSector(allocator, 0, bytes);
    }

    fn writeValidatedSector(self: Device, allocator: std.mem.Allocator, sector: u16, bytes: []const u8) !void {
        if (sector > 5) return error.RefusingUnsafeSector;
        try profile.validate(bytes);
        const info = try self.profileInfo();
        if (info.sector_size != profile.sector_size or bytes.len != info.sector_size)
            return error.UnsupportedLayout;

        const index = try self.session.feature(FeatureId.onboard_profiles);
        _ = self.session.request(index, 6, &.{
            @intCast(sector >> 8),    @intCast(sector & 0xff),    0, 0,
            @intCast(bytes.len >> 8), @intCast(bytes.len & 0xff),
        }) catch |err| switch (err) {
            error.TimedOut, error.InvalidArgument => {},
            else => return err,
        };

        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 16) {
            var chunk: [16]u8 = @splat(0);
            const count = @min(16, bytes.len - offset);
            @memcpy(chunk[0..count], bytes[offset..][0..count]);
            _ = self.session.request(index, 7, chunk[0..count]) catch |err| switch (err) {
                error.TimedOut, error.InvalidArgument => {},
                else => return err,
            };
        }
        _ = self.session.request(index, 8, &.{}) catch |err| switch (err) {
            error.TimedOut, error.InvalidArgument => {},
            else => return err,
        };

        const actual = try self.readSectorValidated(allocator, sector);
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

fn normalizeDpiRange(value: DpiRange) DpiRange {
    return .{
        .min = if (value.min < 100 or value.min > 44_000) 100 else value.min,
        .max = if (value.max < 100 or value.max > 44_000) 44_000 else value.max,
        .step = if (value.step == 0 or value.step > 100) 50 else value.step,
    };
}
