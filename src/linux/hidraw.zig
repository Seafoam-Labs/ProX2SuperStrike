const std = @import("std");
const Transport = @import("../transport.zig").Transport;

pub const HidRaw = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn open(io: std.Io, path: []const u8) !HidRaw {
        if (@import("builtin").os.tag != .linux) return error.UnsupportedOperatingSystem;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
            else => return err,
        };
        return .{ .file = file, .io = io };
    }

    pub fn close(self: *HidRaw) void {
        self.file.close(self.io);
    }

    pub fn transport(self: *HidRaw) Transport {
        return .{
            .context = self,
            .write_fn = writeTransport,
            .read_fn = readTransport,
        };
    }

    fn writeTransport(context: *anyopaque, bytes: []const u8) !void {
        const self: *HidRaw = @ptrCast(@alignCast(context));
        return self.file.writeStreamingAll(self.io, bytes) catch |err| switch (err) {
            error.BrokenPipe, error.NotOpenForWriting => error.Disconnected,
            error.InputOutput => error.InputOutput,
            else => err,
        };
    }

    fn readTransport(context: *anyopaque, buffer: []u8, timeout_ms: u32) !usize {
        const self: *HidRaw = @ptrCast(@alignCast(context));
        var fds = [_]std.posix.pollfd{.{
            .fd = self.file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
        if (ready == 0) return error.TimedOut;
        if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
            return error.Disconnected;
        return self.file.readStreaming(self.io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => error.Disconnected,
            error.InputOutput => error.InputOutput,
            else => err,
        };
    }
};
