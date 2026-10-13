const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const model = @import("model.zig");
const a = std.heap.page_allocator;
pub const Options = struct {
    executable: [:0]const u8 = "px2",
    state_dir: ?[:0]const u8 = null,
    backup_dir: ?[:0]const u8 = null,
    device: ?[:0]const u8 = null,
    connection: ?[:0]const u8 = null,
};
pub const Result = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,
    failure: ?[]const u8,
};
pub const Callback = *const fn (*anyopaque, model.Command, Result) void;
const Pipe = struct {
    job: *Job,
    stream: *gio.InputStream,
    bytes: std.ArrayList(u8) = .empty,
    done: bool = false,
    fn read(self: *Pipe) void {
        self.stream.readBytesAsync(8192, 0, null, received, self);
    }
    fn received(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Pipe = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        const bytes = self.stream.readBytesFinish(result, &err);
        if (err) |e| {
            self.job.fail(std.mem.span(e.f_message orelse "GIO operation failed"));
            e.free();
        }
        if (bytes) |b| {
            defer b.unref();
            var len: usize = 0;
            const ptr = b.getData(&len);
            if (len > 0) {
                // Continue draining after the bound. Never kill a possibly committing write.
                if (len <= model.protocol.max_output - self.bytes.items.len) {
                    self.bytes.appendSlice(a, ptr.?[0..len]) catch self.job.fail("Out of memory while reading px2 output");
                } else self.job.fail("px2 output exceeded the 1 MiB limit");
                self.read();
                return;
            }
        }
        self.done = true;
        self.job.finish();
    }
};
const Job = struct {
    child: *gio.Subprocess,
    command: model.Command,
    out: Pipe,
    err: Pipe,
    callback: Callback,
    context: *anyopaque,
    exited: bool = false,
    failure: ?[]const u8 = null,
    fn fail(self: *Job, message: []const u8) void {
        if (self.failure == null) self.failure = a.dupe(u8, message) catch null;
    }
    fn waited(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        _ = self.child.waitFinish(result, &err);
        if (err) |e| {
            self.fail(std.mem.span(e.f_message orelse "GIO operation failed"));
            e.free();
        }
        self.exited = true;
        self.finish();
    }
    fn finish(self: *Job) void {
        if (!self.exited or !self.out.done or !self.err.done) return;
        self.callback(self.context, self.command, .{
            .ok = self.failure == null and self.child.getSuccessful() != 0,
            .stdout = self.out.bytes.items,
            .stderr = self.err.bytes.items,
            .failure = self.failure,
        });
        self.child.unref();
        self.out.bytes.deinit(a);
        self.err.bytes.deinit(a);
        if (self.failure) |f| a.free(f);
        a.destroy(self);
    }
};
pub fn start(options: Options, command: model.Command, context: *anyopaque, callback: Callback) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    try args.appendSlice(alloc, &.{ options.executable, "--json" });
    inline for (.{ .{ "--state-dir", options.state_dir }, .{ "--backup-dir", options.backup_dir }, .{ "--device", options.device }, .{ "--connection", options.connection } }) |pair| {
        if (pair[1]) |value| try args.appendSlice(alloc, &.{ pair[0], value });
    }
    for (try command.args(alloc)) |arg| try args.append(alloc, try alloc.dupeZ(u8, arg));
    try args.append(alloc, null);
    const job = try a.create(Job);
    var err: ?*glib.Error = null;
    const child = gio.Subprocess.newv(@ptrCast(args.items.ptr), .{ .stdout_pipe = true, .stderr_pipe = true }, &err) orelse {
        a.destroy(job);
        if (err) |e| {
            defer e.free();
            callback(context, command, .{ .ok = false, .stdout = "", .stderr = "", .failure = std.mem.span(e.f_message orelse "GIO operation failed") });
        } else callback(context, command, .{ .ok = false, .stdout = "", .stderr = "", .failure = "Unable to launch px2" });
        return;
    };
    job.* = .{ .child = child, .command = command, .out = .{ .job = job, .stream = child.getStdoutPipe().? }, .err = .{ .job = job, .stream = child.getStderrPipe().? }, .context = context, .callback = callback };
    job.out.read();
    job.err.read();
    child.waitAsync(null, Job.waited, job);
}
