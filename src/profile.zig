const std = @import("std");

pub const sector_size: usize = 255;
// Format 8 stores the live sensor X/Y pair in the final two words of the
// legacy five-word DPI area. The resolution-index byte does not select these
// offsets on the PRO X2 SUPERSTRIKE.
pub const active_dpi_x_offset: usize = 9;
pub const active_dpi_y_offset: usize = 11;

pub const Error = error{
    UnsupportedLayout,
    InvalidCrc,
    InvalidDpi,
    InvalidRate,
    InvalidControlSector,
};

pub const SectorHealth = enum {
    valid,
    blank,
    invalid_crc,
};

pub const ControlEntry = struct {
    slot: u8,
    sector: u16,
    enabled: bool,
};

pub fn crc16CcittFalse(bytes: []const u8) u16 {
    var crc: u16 = 0xffff;
    for (bytes) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            crc = if ((crc & 0x8000) != 0) (crc << 1) ^ 0x1021 else crc << 1;
        }
    }
    return crc;
}

pub fn storedCrc(bytes: []const u8) Error!u16 {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    return readBe16(bytes[bytes.len - 2 ..][0..2]);
}

pub fn validate(bytes: []const u8) Error!void {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    if (try storedCrc(bytes) != crc16CcittFalse(bytes[0 .. bytes.len - 2]))
        return error.InvalidCrc;
}

pub fn health(bytes: []const u8) SectorHealth {
    if (bytes.len != sector_size) return .invalid_crc;
    var all_zero = true;
    var all_ff = true;
    for (bytes) |byte| {
        all_zero = all_zero and byte == 0;
        all_ff = all_ff and byte == 0xff;
    }
    if (all_zero or all_ff) return .blank;
    validate(bytes) catch return .invalid_crc;
    return .valid;
}

pub fn parseControl(bytes: []const u8, profile_count: u8, entries: *[8]ControlEntry) Error![]const ControlEntry {
    if (bytes.len < 6) return error.InvalidControlSector;
    if (profile_count == 0 or profile_count > entries.len) return error.InvalidControlSector;
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + 3 < bytes.len - 2 and count < profile_count) : (offset += 4) {
        const sector = readBe16(bytes[offset..][0..2]);
        if (sector == 0xffff) break;
        const slot: u8 = @intCast(count + 1);
        const low: u8 = @intCast(sector & 0xff);
        if (low == 0 or low > profile_count) return error.InvalidControlSector;
        entries[count] = .{ .slot = slot, .sector = sector, .enabled = bytes[offset + 2] == 1 };
        count += 1;
    }
    if (count == 0) return error.InvalidControlSector;
    return entries[0..count];
}

pub fn controlForRam(bytes: []const u8, profile_count: u8, destination: []u8) Error!void {
    if (bytes.len != sector_size or destination.len != sector_size) return error.UnsupportedLayout;
    @memset(destination, 0xff);
    var entries: [8]ControlEntry = undefined;
    const parsed = try parseControl(bytes, profile_count, &entries);
    for (0..profile_count) |index| {
        const slot: u8 = @intCast(index + 1);
        var enabled = false;
        for (parsed) |entry| {
            if (entry.slot == slot) {
                enabled = entry.enabled;
                break;
            }
        }
        destination[index * 4] = 0;
        destination[index * 4 + 1] = slot;
        destination[index * 4 + 2] = @intFromBool(enabled);
        destination[index * 4 + 3] = 0xff;
    }
    try refreshCrc(destination);
}

pub fn refreshCrc(bytes: []u8) Error!void {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    writeBe16(bytes[bytes.len - 2 ..][0..2], crc16CcittFalse(bytes[0 .. bytes.len - 2]));
}

pub fn dpi(bytes: []const u8) Error!struct { x: u16, y: u16 } {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    return .{
        .x = readLe16(bytes[active_dpi_x_offset..][0..2]),
        .y = readLe16(bytes[active_dpi_y_offset..][0..2]),
    };
}

pub fn setDpi(bytes: []u8, value: u16) Error!void {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    if (value < 100 or value > 44_000) return error.InvalidDpi;
    writeLe16(bytes[active_dpi_x_offset..][0..2], value);
    writeLe16(bytes[active_dpi_y_offset..][0..2], value);
    try refreshCrc(bytes);
}

pub fn reportRate(bytes: []const u8) Error!u16 {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    if (bytes[0] > 6) return error.InvalidRate;
    return @as(u16, 125) << @intCast(bytes[0]);
}

pub fn rateIndex(hz: u16) Error!u8 {
    return switch (hz) {
        125 => 0,
        250 => 1,
        500 => 2,
        1000 => 3,
        2000 => 4,
        4000 => 5,
        8000 => 6,
        else => error.InvalidRate,
    };
}

pub fn setReportRate(bytes: []u8, hz: u16) Error!void {
    if (bytes.len != sector_size) return error.UnsupportedLayout;
    bytes[0] = try rateIndex(hz);
    try refreshCrc(bytes);
}

fn readLe16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn writeLe16(bytes: *[2]u8, value: u16) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast(value >> 8);
}

fn readBe16(bytes: *const [2]u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn writeBe16(bytes: *[2]u8, value: u16) void {
    bytes[0] = @intCast(value >> 8);
    bytes[1] = @intCast(value & 0xff);
}

test "CRC-16/CCITT-FALSE standard vector" {
    try std.testing.expectEqual(@as(u16, 0x29b1), crc16CcittFalse("123456789"));
}

test "profile mutations preserve unrelated bytes and refresh CRC" {
    var bytes: [sector_size]u8 = @splat(0xa5);
    bytes[0] = 3;
    bytes[1] = 3;
    writeLe16(bytes[active_dpi_x_offset..][0..2], 1200);
    writeLe16(bytes[active_dpi_y_offset..][0..2], 1200);
    try refreshCrc(&bytes);
    try validate(&bytes);

    const before = bytes;
    try setDpi(&bytes, 1600);
    try validate(&bytes);
    const current = try dpi(&bytes);
    try std.testing.expectEqual(@as(u16, 1600), current.x);
    try std.testing.expectEqual(@as(u16, 1600), current.y);
    for (bytes, 0..) |byte, i| {
        const intentionally_changed = (i >= active_dpi_x_offset and i <= active_dpi_y_offset + 1) or
            i >= sector_size - 2;
        if (!intentionally_changed) try std.testing.expectEqual(before[i], byte);
    }

    const after_dpi = bytes;
    try setReportRate(&bytes, 500);
    try validate(&bytes);
    for (bytes, 0..) |byte, i| {
        const intentionally_changed = i == 0 or i >= sector_size - 2;
        if (!intentionally_changed) try std.testing.expectEqual(after_dpi[i], byte);
    }
}

test "format 8 live DPI pair ignores the resolution index" {
    var bytes: [sector_size]u8 = @splat(0xff);
    bytes[0] = 3;
    bytes[1] = 3;
    writeLe16(bytes[active_dpi_x_offset..][0..2], 2400);
    writeLe16(bytes[active_dpi_y_offset..][0..2], 2400);
    try refreshCrc(&bytes);
    const current = try dpi(&bytes);
    try std.testing.expectEqual(@as(u16, 2400), current.x);
    try std.testing.expectEqual(@as(u16, 2400), current.y);
}

test "sector health distinguishes blank, corrupt, and valid data" {
    var bytes: [sector_size]u8 = @splat(0);
    try std.testing.expectEqual(SectorHealth.blank, health(&bytes));
    bytes[0] = 3;
    try std.testing.expectEqual(SectorHealth.invalid_crc, health(&bytes));
    try refreshCrc(&bytes);
    try std.testing.expectEqual(SectorHealth.valid, health(&bytes));
}

test "ROM control tables are converted to writable RAM addresses" {
    var rom: [sector_size]u8 = @splat(0xff);
    rom[0] = 0x01;
    rom[1] = 0x01;
    rom[2] = 1;
    rom[3] = 0;
    rom[4] = 0xff;
    rom[5] = 0xff;

    var entries: [8]ControlEntry = undefined;
    const parsed = try parseControl(&rom, 2, &entries);
    try std.testing.expectEqual(@as(u16, 0x0101), parsed[0].sector);
    try std.testing.expect(parsed[0].enabled);

    var ram: [sector_size]u8 = undefined;
    try controlForRam(&rom, 2, &ram);
    try validate(&ram);
    try std.testing.expectEqual(@as(u8, 0), ram[0]);
    try std.testing.expectEqual(@as(u8, 1), ram[1]);
    try std.testing.expectEqual(@as(u8, 0), ram[4]);
    try std.testing.expectEqual(@as(u8, 2), ram[5]);
    try std.testing.expectEqual(@as(u8, 0), ram[6]);
}
