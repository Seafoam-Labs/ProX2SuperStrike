const std = @import("std");

pub const sector_size: usize = 255;
pub const active_dpi_x_offset: usize = 9;
pub const active_dpi_y_offset: usize = 11;
pub const write_count_offset: usize = 18;

pub const Error = error{
    UnsupportedLayout,
    InvalidCrc,
    InvalidDpi,
    InvalidRate,
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
    bumpWriteCount(bytes);
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
    bumpWriteCount(bytes);
    try refreshCrc(bytes);
}

fn bumpWriteCount(bytes: []u8) void {
    const current = readLe16(bytes[write_count_offset..][0..2]);
    writeLe16(bytes[write_count_offset..][0..2], current +% 1);
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
    writeLe16(bytes[write_count_offset..][0..2], 41);
    try refreshCrc(&bytes);
    try validate(&bytes);

    const before = bytes;
    try setDpi(&bytes, 1600);
    try validate(&bytes);
    const current = try dpi(&bytes);
    try std.testing.expectEqual(@as(u16, 1600), current.x);
    try std.testing.expectEqual(@as(u16, 1600), current.y);
    try std.testing.expectEqual(@as(u16, 42), readLe16(bytes[write_count_offset..][0..2]));
    for (bytes, 0..) |byte, i| {
        const intentionally_changed = (i >= 9 and i <= 12) or
            (i >= 18 and i <= 19) or i >= sector_size - 2;
        if (!intentionally_changed) try std.testing.expectEqual(before[i], byte);
    }
}
