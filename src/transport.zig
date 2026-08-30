const std = @import("std");

pub const Error = error{
    TimedOut,
    Disconnected,
    PermissionDenied,
    WouldBlock,
    InputOutput,
};

/// A small runtime interface so HID++ can be tested without a physical mouse.
pub const Transport = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    read_fn: *const fn (*anyopaque, []u8, u32) anyerror!usize,

    pub fn write(self: Transport, bytes: []const u8) !void {
        return self.write_fn(self.context, bytes);
    }

    pub fn read(self: Transport, buffer: []u8, timeout_ms: u32) !usize {
        return self.read_fn(self.context, buffer, timeout_ms);
    }
};

pub const Mock = struct {
    expected_write: []const u8,
    reply: []const u8,
    wrote: bool = false,

    pub fn transport(self: *Mock) Transport {
        return .{
            .context = self,
            .write_fn = write,
            .read_fn = read,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *Mock = @ptrCast(@alignCast(context));
        try std.testing.expectEqualSlices(u8, self.expected_write, bytes);
        self.wrote = true;
    }

    fn read(context: *anyopaque, buffer: []u8, timeout_ms: u32) !usize {
        _ = timeout_ms;
        const self: *Mock = @ptrCast(@alignCast(context));
        if (!self.wrote) return error.WouldBlock;
        if (buffer.len < self.reply.len) return error.NoSpaceLeft;
        @memcpy(buffer[0..self.reply.len], self.reply);
        return self.reply.len;
    }
};
