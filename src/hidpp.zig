const std = @import("std");
const Transport = @import("transport.zig").Transport;

pub const short_report_id: u8 = 0x10;
pub const long_report_id: u8 = 0x11;
pub const short_report_size: usize = 7;
pub const long_report_size: usize = 20;

pub const ProtocolError = error{
    InvalidArgument,
    OutOfRange,
    HardwareError,
    InvalidFeatureIndex,
    InvalidFunction,
    Busy,
    Unsupported,
    UnexpectedResponse,
    TooManyNotifications,
    InvalidFrame,
};

pub const Response = struct {
    bytes: [long_report_size]u8,
    len: usize,

    pub fn params(self: *const Response) []const u8 {
        return self.bytes[4..self.len];
    }
};

pub const Session = struct {
    transport: Transport,
    device_index: u8,
    software_id: u4 = 0x0a,
    timeout_ms: u32 = 750,

    pub fn request(self: *Session, feature_index: u8, function: u4, params: []const u8) !Response {
        if (params.len > long_report_size - 4) return error.InvalidArgument;

        var request_bytes: [long_report_size]u8 = @splat(0);
        request_bytes[0] = long_report_id;
        request_bytes[1] = self.device_index;
        request_bytes[2] = feature_index;
        request_bytes[3] = (@as(u8, function) << 4) | self.software_id;
        @memcpy(request_bytes[4..][0..params.len], params);
        try self.transport.write(&request_bytes);

        var skipped: usize = 0;
        while (skipped < 64) : (skipped += 1) {
            var response: Response = .{ .bytes = @splat(0), .len = 0 };
            response.len = try self.transport.read(&response.bytes, self.timeout_ms);
            if (response.len != short_report_size and response.len != long_report_size)
                continue;
            if (response.bytes[0] != short_report_id and response.bytes[0] != long_report_id)
                continue;
            if (response.bytes[1] != self.device_index)
                continue;

            if (response.bytes[2] == 0xff and response.len >= 7 and
                response.bytes[3] == feature_index and
                response.bytes[4] == request_bytes[3])
            {
                return hidppError(response.bytes[5]);
            }

            if (response.bytes[2] != feature_index or response.bytes[3] != request_bytes[3])
                continue;
            return response;
        }
        return error.TooManyNotifications;
    }

    pub fn feature(self: *Session, feature_id: u16) !u8 {
        const response = try self.request(0, 0, &.{
            @intCast(feature_id >> 8),
            @intCast(feature_id & 0xff),
        });
        if (response.params().len == 0 or response.params()[0] == 0)
            return error.Unsupported;
        return response.params()[0];
    }
};

fn hidppError(code: u8) ProtocolError {
    return switch (code) {
        0x02 => error.InvalidArgument,
        0x03 => error.OutOfRange,
        0x04 => error.HardwareError,
        0x06 => error.InvalidFeatureIndex,
        0x07 => error.InvalidFunction,
        0x08 => error.Busy,
        else => error.UnexpectedResponse,
    };
}

test "session builds and correlates a long request" {
    const transport = @import("transport.zig");
    const request_bytes = [_]u8{ 0x11, 0x01, 0x0c, 0x2a, 0x00 } ++ [_]u8{0} ** 15;
    const reply = [_]u8{ 0x11, 0x01, 0x0c, 0x2a, 0x00, 0x14, 0x09, 0x0c } ++ [_]u8{0} ** 12;
    var mock: transport.Mock = .{ .expected_write = &request_bytes, .reply = &reply };
    var session: Session = .{ .transport = mock.transport(), .device_index = 1 };
    const response = try session.request(0x0c, 2, &.{0});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x14, 0x09, 0x0c }, response.params()[0..4]);
}

test "session decodes HID++ errors" {
    const transport = @import("transport.zig");
    const request_bytes = [_]u8{ 0x11, 0xff, 0x0c, 0x1a } ++ [_]u8{0} ** 16;
    const reply = [_]u8{ 0x10, 0xff, 0xff, 0x0c, 0x1a, 0x02, 0x00 };
    var mock: transport.Mock = .{ .expected_write = &request_bytes, .reply = &reply };
    var session: Session = .{ .transport = mock.transport(), .device_index = 0xff };
    try std.testing.expectError(error.InvalidArgument, session.request(0x0c, 1, &.{}));
}
