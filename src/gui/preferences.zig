const std = @import("std");
pub const Appearance = enum { dark, light, system };
pub const Preferences = struct {
    schema_version: u8 = 1,
    appearance: Appearance = .dark,
    width: i32 = 1120,
    height: i32 = 820,
    pub fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) Preferences {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)) catch return .{};
        defer a.free(bytes);
        const parsed = std.json.parseFromSlice(Preferences, a, bytes, .{}) catch return .{};
        defer parsed.deinit();
        var value = parsed.value;
        if (value.schema_version != 1) return .{};
        value.width = std.math.clamp(value.width, 390, 3840);
        value.height = std.math.clamp(value.height, 400, 2160);
        return value;
    }
    pub fn save(self: Preferences, io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        const bytes = try std.json.Stringify.valueAlloc(a, self, .{ .whitespace = .indent_2 });
        defer a.free(bytes);
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = .fromMode(0o600) });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, bytes);
        try file.file.sync(io);
        try file.replace(io);
    }
};
