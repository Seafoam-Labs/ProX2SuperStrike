const std = @import("std");
const cli = @import("cli.zig");

test {
    _ = cli;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    var stderr_file = std.Io.File.Writer.init(.stderr(), init.io, &stderr_buffer);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    cli.run(init, stdout, stderr) catch |err| {
        try stderr.print("px2: {s}\n", .{@errorName(err)});
        try stdout.flush();
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
    try stderr.flush();
}
