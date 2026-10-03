const std = @import("std");
const profile = @import("profile.zig");
const state = @import("state.zig");
const Device = @import("device.zig").Device;

pub fn mirror(io: std.Io, device: anytype, bytes: []const u8) !void {
    try profile.validate(bytes);
    const dpi = try profile.dpi(bytes);
    const rate = try profile.reportRate(bytes);
    if (dpi.x < 100 or dpi.x > 44000 or dpi.y < 100 or dpi.y > 44000) return error.InvalidDpi;
    try device.setOnboardMode(2);
    try std.Io.sleep(io, .fromMilliseconds(120), .awake);
    try device.setCurrentDpiXY(dpi.x, dpi.y);
    try device.setCurrentRate(rate);
    try std.Io.sleep(io, .fromMilliseconds(120), .awake);
}

pub fn hits(device: anytype, buttons: [2]state.Hits) !void {
    for (buttons, 0..) |desired, button| {
        if (desired.actuation == null and desired.rapid_trigger == null and desired.haptics == null) continue;
        const actual = try device.setHits(@intCast(button), desired.actuation, desired.rapid_trigger, desired.haptics);
        if (desired.actuation) |v| if (v != actual.actuation) return error.HitsVerificationFailed;
        if (desired.rapid_trigger) |v| if (v != actual.rapid_trigger) return error.HitsVerificationFailed;
        if (desired.haptics) |v| if (v != actual.haptics) return error.HitsVerificationFailed;
    }
}

pub fn apply(io: std.Io, allocator: std.mem.Allocator, device: Device, desired: state.Desired) !void {
    try desired.validate();
    const sector = desired.sector orelse return error.NoDesiredProfile;
    const info = try device.profileInfo();
    if (info.memory_model != 1 or info.format != 8 or info.sector_size != profile.sector_size)
        return error.UnsupportedLayout;
    if (desired.slot().? > info.count) return error.InvalidProfile;
    const bytes = try device.readSectorValidated(allocator, sector);
    defer allocator.free(bytes);
    try profile.validate(bytes);
    const dpi = try profile.dpi(bytes);
    if (dpi.x < 100 or dpi.x > 44000 or dpi.y < 100 or dpi.y > 44000) return error.InvalidDpi;
    _ = try profile.reportRate(bytes);
    // Activation and live setters only. Never commit a sector during recovery.
    try device.activateProfile(sector);
    try mirror(io, device, bytes);
    try hits(device, desired.hits[desired.slot().? - 1]);
}

// A simulated HID++ device checks the real transport sequence, rejects every
// flash-write function, and deliberately returns stale live DPI/rate values.
const SimulatedMouse = struct {
    sector: [profile.sector_size]u8 = @splat(0),
    reply: [20]u8 = @splat(0),
    mode: u8 = 1,
    active_sector: u16 = 0,
    dpi_x: u16 = 0,
    dpi_y: u16 = 0,
    rate_index: u8 = 0,
    button_values: [2][3]u8 = @splat(.{ 2, 2, 2 }),
    mutations: usize = 0,
    fail_rate_once: bool = false,

    fn transport(self: *SimulatedMouse) @import("transport.zig").Transport {
        return .{ .context = self, .write_fn = write, .read_fn = read };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *SimulatedMouse = @ptrCast(@alignCast(context));
        self.reply = @splat(0);
        @memcpy(self.reply[0..4], bytes[0..4]);
        const feature = bytes[2];
        const function = bytes[3] >> 4;
        const p = bytes[4..];
        const result = self.reply[4..];
        if (feature == 0) {
            result[0] = switch ((@as(u16, p[0]) << 8) | p[1]) {
                0x8100 => 1,
                0x2202 => 2,
                0x8061 => 3,
                0x1b0c => 4,
                else => return error.UnexpectedFeature,
            };
            return;
        }
        switch (feature) {
            1 => switch (function) {
                0 => @memcpy(result[0..9], &[_]u8{ 1, 8, 0, 5, 0, 2, 0, 0, 255 }),
                5 => {
                    try std.testing.expectEqual(@as(u8, 3), p[1]);
                    const offset = (@as(usize, p[2]) << 8) | p[3];
                    @memcpy(result, self.sector[offset..][0..16]);
                },
                1 => {
                    self.mode = p[0];
                    self.mutations += 1;
                },
                3 => {
                    try std.testing.expectEqual(@as(u8, 1), self.mode);
                    self.active_sector = (@as(u16, p[0]) << 8) | p[1];
                    self.mutations += 1;
                },
                6, 7, 8 => return error.UnexpectedFlashWrite,
                else => return error.UnexpectedFunction,
            },
            2 => switch (function) {
                5 => result[9] = 2, // Stale DPI, but preserve lift-off distance.
                6 => {
                    try std.testing.expectEqual(@as(u8, 2), self.mode);
                    try std.testing.expectEqual(@as(u8, 2), p[5]);
                    self.dpi_x = (@as(u16, p[1]) << 8) | p[2];
                    self.dpi_y = (@as(u16, p[3]) << 8) | p[4];
                    self.mutations += 1;
                },
                else => return error.UnexpectedFunction,
            },
            3 => {
                try std.testing.expectEqual(@as(u8, 3), function);
                if (self.fail_rate_once) {
                    self.fail_rate_once = false;
                    return error.TimedOut;
                }
                self.rate_index = p[0];
                self.mutations += 1;
            },
            4 => switch (function) {
                0 => @memcpy(result[0..5], &[_]u8{ 0, 2, 40, 40, 40 }),
                1 => {
                    self.button_values[p[0]] = .{ p[1] >> 2, p[2] >> 2, p[3] >> 2 };
                    self.mutations += 1;
                },
                2 => {
                    const button = self.button_values[p[0]];
                    @memcpy(result[0..4], &[_]u8{ p[0], button[0] << 2, (button[1] << 2) | 1, button[2] << 2 });
                },
                else => return error.UnexpectedFunction,
            },
            else => return error.UnexpectedFeature,
        }
    }

    fn read(context: *anyopaque, bytes: []u8, _: u32) !usize {
        const self: *SimulatedMouse = @ptrCast(@alignCast(context));
        @memcpy(bytes[0..20], &self.reply);
        return 20;
    }
};

test "recovery restores the selected profile and explicit HITS without writing memory" {
    var mouse: SimulatedMouse = .{};
    try profile.setDpi(&mouse.sector, 1600);
    mouse.sector[profile.active_dpi_y_offset] = 0x20;
    mouse.sector[profile.active_dpi_y_offset + 1] = 0x03; // Independent Y = 800.
    try profile.setReportRate(&mouse.sector, 2000);
    const original = mouse.sector;
    var session: @import("hidpp.zig").Session = .{ .transport = mouse.transport(), .device_index = 1 };
    var desired: state.Desired = .{ .sector = 3 };
    desired.hits[2][0].haptics = 0;
    try apply(std.testing.io, std.testing.allocator, .{ .session = &session }, desired);
    try std.testing.expectEqual(@as(u16, 3), mouse.active_sector);
    try std.testing.expectEqual(@as(u16, 1600), mouse.dpi_x);
    try std.testing.expectEqual(@as(u16, 800), mouse.dpi_y);
    try std.testing.expectEqual(@as(u8, 4), mouse.rate_index);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 0 }, &mouse.button_values[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 2 }, &mouse.button_values[1]);
    try std.testing.expectEqualSlices(u8, &original, &mouse.sector);
}

test "recovery fails before mutation on corrupt profiles and retries partial live application" {
    var mouse: SimulatedMouse = .{};
    try profile.setDpi(&mouse.sector, 2400);
    try profile.setReportRate(&mouse.sector, 1000);
    var session: @import("hidpp.zig").Session = .{ .transport = mouse.transport(), .device_index = 1 };
    const device: Device = .{ .session = &session };
    const desired: state.Desired = .{ .sector = 3 };
    mouse.sector[30] ^= 1;
    try std.testing.expectError(error.InvalidCrc, apply(std.testing.io, std.testing.allocator, device, desired));
    try std.testing.expectEqual(@as(usize, 0), mouse.mutations);
    mouse.sector[30] ^= 1;
    mouse.fail_rate_once = true;
    try std.testing.expectError(error.TimedOut, apply(std.testing.io, std.testing.allocator, device, desired));
    try apply(std.testing.io, std.testing.allocator, device, desired);
    try std.testing.expectEqual(@as(u16, 2400), mouse.dpi_x);
    try std.testing.expectEqual(@as(u8, 3), mouse.rate_index);
}
