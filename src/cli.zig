const std = @import("std");
const core = @import("superstrike");

const Candidate = core.discovery.Candidate;
const Connection = core.discovery.Connection;
const Device = core.device.Device;
const HitsConfig = core.device.HitsConfig;

const Options = struct {
    json: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
    connection: core.discovery.Filter = .auto,
    device_path: ?[]const u8 = null,
    timeout_ms: u32 = 750,
    profile: ?u8 = null,
};

pub fn run(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const parsed = try parseArgs(allocator, args[1..]);
    const options = parsed.options;
    const words = parsed.words;

    if (words.len == 0 or eql(words[0], "help") or eql(words[0], "--help")) {
        try printHelp(stdout);
        return;
    }

    if (eql(words[0], "list")) {
        return list(init.io, allocator, options, stdout);
    }

    var connected = core.discovery.connect(
        init.io,
        allocator,
        options.connection,
        options.device_path,
        options.timeout_ms,
    ) catch |err| {
        try explainConnectError(stderr, err);
        return err;
    };
    defer connected.close(allocator);
    const device = Device{ .session = &connected.session };

    if (eql(words[0], "status"))
        return status(device, connected.candidate, options, stdout);
    if (eql(words[0], "doctor"))
        return doctor(init.io, allocator, device, connected.candidate, options, stdout);
    if (eql(words[0], "get"))
        return get(allocator, device, words, options, stdout);
    if (eql(words[0], "set"))
        return set(init.io, allocator, device, words, options, stdout);
    if (eql(words[0], "profile"))
        return profileCommand(init.io, allocator, device, words, options, stdout);
    if (eql(words[0], "rate") and words.len >= 2 and eql(words[1], "measure"))
        return measureRate(init.io, connected.candidate, options, stdout);

    try stderr.print("unknown command: {s}\n\n", .{words[0]});
    try printHelp(stderr);
    return error.InvalidCommand;
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !struct { options: Options, words: []const []const u8 } {
    var options: Options = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--json")) {
            options.json = true;
        } else if (eql(arg, "--dry-run")) {
            options.dry_run = true;
        } else if (eql(arg, "--verbose")) {
            options.verbose = true;
        } else if (eql(arg, "--connection")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.connection = try parseConnection(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--connection=")) {
            options.connection = try parseConnection(arg[13..]);
        } else if (eql(arg, "--device")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.device_path = args[i];
        } else if (eql(arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (eql(arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.profile = try std.fmt.parseInt(u8, args[i], 10);
        } else {
            try words.append(allocator, arg);
        }
    }
    return .{ .options = options, .words = try words.toOwnedSlice(allocator) };
}

fn list(io: std.Io, allocator: std.mem.Allocator, options: Options, out: *std.Io.Writer) !void {
    const candidates = try core.discovery.scan(io, allocator);
    if (options.json) {
        try writeJson(out, candidates);
        return;
    }
    if (candidates.len == 0) {
        try out.writeAll("No PRO X2 SUPERSTRIKE HID interfaces found.\n");
        return;
    }
    for (candidates) |candidate| {
        try out.print("{s}  {s}  {x:0>4}:{x:0>4}  {s}\n", .{
            candidate.path,
            @tagName(candidate.connection),
            candidate.vid,
            candidate.pid,
            candidate.name,
        });
    }
}

fn status(device: Device, candidate: Candidate, options: Options, out: *std.Io.Writer) !void {
    const battery = try device.battery();
    const left = try device.hitsConfig(0);
    const right = try device.hitsConfig(1);
    const dpi = try device.currentDpi();
    const rate = try device.currentRate();
    const active_sector = try device.currentProfile();
    const active_profile = try profileSlot(active_sector);
    const value = .{
        .path = candidate.path,
        .name = candidate.name,
        .connection = candidate.connection,
        .device_index = device.session.device_index,
        .battery_percent = battery.percent,
        .charging = battery.charging(),
        .charging_state = battery.charging_state,
        .active_profile = active_profile,
        .active_sector = active_sector,
        .reported_dpi_x = dpi.x,
        .reported_dpi_y = dpi.y,
        .reported_rate_hz = rate,
        .left_hits = left,
        .right_hits = right,
    };
    if (options.json) return writeJson(out, value);
    try out.print(
        \\Device: {s} ({s}, index 0x{x:0>2})
        \\Path: {s}
        \\Battery: {d}%{s}
        \\Active profile: {d} (sector 0x{x:0>4})
        \\Reported DPI: {d} x {d} (firmware may return a stale value)
        \\Reported rate: {d} Hz (firmware may return a stale value)
        \\Left HITS: actuation {d}, rapid {d}, haptics {d}
        \\Right HITS: actuation {d}, rapid {d}, haptics {d}
        \\
    , .{
        candidate.name,
        @tagName(candidate.connection),
        device.session.device_index,
        candidate.path,
        battery.percent,
        if (battery.charging()) " (charging)" else "",
        active_profile,
        active_sector,
        dpi.x,
        dpi.y,
        rate,
        left.actuation,
        left.rapid_trigger,
        left.haptics,
        right.actuation,
        right.rapid_trigger,
        right.haptics,
    });
}

fn doctor(io: std.Io, allocator: std.mem.Allocator, device: Device, candidate: Candidate, options: Options, out: *std.Io.Writer) !void {
    const candidates = try core.discovery.scan(io, allocator);
    const features = try device.featureTable(allocator);
    if (options.json) {
        return writeJson(out, .{
            .selected = candidate,
            .device_index = device.session.device_index,
            .candidates = candidates,
            .features = features,
        });
    }
    try out.print("Selected {s} ({s}), device index 0x{x:0>2}\n", .{
        candidate.path, @tagName(candidate.connection), device.session.device_index,
    });
    try out.print("Candidates: {d}\nFeatures ({d}):", .{ candidates.len, features.len });
    for (features) |feature_id| try out.print(" 0x{x:0>4}", .{feature_id});
    try out.writeByte('\n');
}

fn get(allocator: std.mem.Allocator, device: Device, words: []const []const u8, options: Options, out: *std.Io.Writer) !void {
    if (words.len < 2) return error.MissingSubcommand;
    if (eql(words[1], "hits")) {
        const caps = try device.hitsCapabilities();
        const left = try device.hitsConfig(0);
        const right = try device.hitsConfig(1);
        if (options.json) return writeJson(out, .{ .capabilities = caps, .left = left, .right = right });
        try out.print("limits: actuation 1-{d}, rapid 1-{d}, haptics 0-{d}\n", .{
            caps.max_actuation, caps.max_rapid_trigger, caps.max_haptics,
        });
        try printHits(out, "left", left);
        try printHits(out, "right", right);
        return;
    }
    if (eql(words[1], "profiles")) return listProfiles(allocator, device, options, out);
    if (eql(words[1], "dpi") or eql(words[1], "rate")) {
        const active_sector = try device.currentProfile();
        const active = try profileSlot(active_sector);
        const bytes = try device.readSector(allocator, active_sector);
        defer allocator.free(bytes);
        try core.profile.validate(bytes);
        const saved_dpi = try core.profile.dpi(bytes);
        const saved_rate = try core.profile.reportRate(bytes);
        if (eql(words[1], "dpi")) {
            const supported = try device.dpiRange();
            if (options.json) return writeJson(out, .{
                .profile = active,
                .saved_dpi_x = saved_dpi.x,
                .saved_dpi_y = saved_dpi.y,
                .supported = supported,
            });
            try out.print("profile {d}: {d} x {d} DPI (supported {d}-{d}, step {d})\n", .{
                active, saved_dpi.x, saved_dpi.y, supported.min, supported.max, supported.step,
            });
        } else {
            const mask = try device.supportedRateMask();
            if (options.json) return writeJson(out, .{
                .profile = active,
                .saved_rate_hz = saved_rate,
                .supported_mask = mask,
            });
            try out.print("profile {d}: {d} Hz (supported:", .{ active, saved_rate });
            for ([_]u16{ 125, 250, 500, 1000, 2000, 4000, 8000 }, 0..) |hz, index| {
                if ((mask & (@as(u16, 1) << @intCast(index))) != 0) try out.print(" {d}", .{hz});
            }
            try out.writeAll(")\n");
        }
        return;
    }
    return error.InvalidSubcommand;
}

fn set(io: std.Io, allocator: std.mem.Allocator, device: Device, words: []const []const u8, options: Options, out: *std.Io.Writer) !void {
    if (words.len < 2) return error.MissingSubcommand;
    if (eql(words[1], "hits")) return setHits(device, words, options, out);
    if (eql(words[1], "dpi") or eql(words[1], "rate")) {
        if (words.len < 3) return error.MissingValue;
        const numeric = try std.fmt.parseInt(u16, words[2], 10);
        const sector = try selectedProfile(device, options.profile);
        const bytes = try device.readSector(allocator, sector);
        defer allocator.free(bytes);
        try core.profile.validate(bytes);
        const setting_dpi = eql(words[1], "dpi");
        if (setting_dpi) {
            const supported = try device.dpiRange();
            if (!supported.supports(numeric)) return error.UnsupportedDpi;
        } else {
            const rate_index = try core.profile.rateIndex(numeric);
            const mask = try device.supportedRateMask();
            if ((mask & (@as(u16, 1) << @intCast(rate_index))) == 0) return error.UnsupportedRate;
        }
        if (!options.dry_run) try saveBackup(io, sector, bytes, out);
        if (setting_dpi)
            try core.profile.setDpi(bytes, numeric)
        else
            try core.profile.setReportRate(bytes, numeric);

        if (options.dry_run) {
            try out.print("dry run: profile {d} would be updated to {s} {d}\n", .{ sector, words[1], numeric });
            return;
        }
        try device.writeSector(allocator, sector, bytes);
        if (try profileSlot(try device.currentProfile()) == sector) try device.activateProfile(sector);
        try out.print("profile {d} updated: {s} {d}\n", .{ sector, words[1], numeric });
        return;
    }
    return error.InvalidSubcommand;
}

fn setHits(device: Device, words: []const []const u8, options: Options, out: *std.Io.Writer) !void {
    if (words.len < 3) return error.MissingButton;
    const first: u8, const last: u8 = if (eql(words[2], "left"))
        .{ 0, 0 }
    else if (eql(words[2], "right"))
        .{ 1, 1 }
    else if (eql(words[2], "both"))
        .{ 0, 1 }
    else
        return error.InvalidButton;

    var actuation: ?u8 = null;
    var rapid: ?u8 = null;
    var haptics: ?u8 = null;
    var i: usize = 3;
    while (i < words.len) : (i += 1) {
        const slot: *?u8 = if (eql(words[i], "--actuation"))
            &actuation
        else if (eql(words[i], "--rapid"))
            &rapid
        else if (eql(words[i], "--haptics"))
            &haptics
        else
            return error.InvalidOption;
        i += 1;
        if (i >= words.len) return error.MissingOptionValue;
        slot.* = try std.fmt.parseInt(u8, words[i], 10);
    }
    if (actuation == null and rapid == null and haptics == null) return error.MissingValue;

    const caps = try device.hitsCapabilities();
    if (actuation) |v| if (v < 1 or v > caps.max_actuation) return error.InvalidActuation;
    if (rapid) |v| if (v < 1 or v > caps.max_rapid_trigger) return error.InvalidRapidTrigger;
    if (haptics) |v| if (v > caps.max_haptics) return error.InvalidHaptics;

    var button = first;
    while (button <= last) : (button += 1) {
        const current = try device.hitsConfig(button);
        if (options.dry_run) {
            try out.print("dry run: {s}: actuation {d}->{d}, rapid {d}->{d}, haptics {d}->{d}\n", .{
                buttonName(button),
                current.actuation,
                actuation orelse current.actuation,
                current.rapid_trigger,
                rapid orelse current.rapid_trigger,
                current.haptics,
                haptics orelse current.haptics,
            });
        } else {
            const updated = try device.setHits(button, actuation, rapid, haptics);
            try printHits(out, buttonName(button), updated);
        }
        if (button == 255) break;
    }
}

fn profileCommand(io: std.Io, allocator: std.mem.Allocator, device: Device, words: []const []const u8, options: Options, out: *std.Io.Writer) !void {
    if (words.len < 2) return error.MissingSubcommand;
    if (eql(words[1], "list")) return listProfiles(allocator, device, options, out);
    if (words.len < 3) return error.MissingProfile;
    const sector = try std.fmt.parseInt(u8, words[2], 10);
    try validateProfileNumber(device, sector);

    if (eql(words[1], "show")) {
        const bytes = try device.readSector(allocator, sector);
        defer allocator.free(bytes);
        try core.profile.validate(bytes);
        return showProfile(out, sector, bytes, options.json);
    }
    if (eql(words[1], "activate")) {
        if (options.dry_run) {
            try out.print("dry run: profile {d} would be activated\n", .{sector});
            return;
        }
        try device.activateProfile(sector);
        try out.print("profile {d} activated\n", .{sector});
        return;
    }
    if (eql(words[1], "export")) {
        if (words.len < 4) return error.MissingPath;
        const bytes = try device.readSector(allocator, sector);
        defer allocator.free(bytes);
        try core.profile.validate(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = words[3], .data = bytes });
        try out.print("profile {d} exported to {s}\n", .{ sector, words[3] });
        return;
    }
    if (eql(words[1], "apply")) {
        if (words.len < 4) return error.MissingPath;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, words[3], allocator, .limited(4096));
        try core.profile.validate(bytes);
        const original = try device.readSector(allocator, sector);
        defer allocator.free(original);
        try core.profile.validate(original);
        if (options.dry_run) {
            try out.print("dry run: {s} would be applied to profile {d}\n", .{ words[3], sector });
            return;
        }
        try saveBackup(io, sector, original, out);
        try device.writeSector(allocator, sector, bytes);
        if (try profileSlot(try device.currentProfile()) == sector) try device.activateProfile(sector);
        try out.print("{s} applied and verified as profile {d}\n", .{ words[3], sector });
        return;
    }
    return error.InvalidSubcommand;
}

const ProfileSummary = struct {
    sector: u8,
    active: bool,
    dpi_x: u16,
    dpi_y: u16,
    rate_hz: u16,
    crc_valid: bool,
};

fn listProfiles(allocator: std.mem.Allocator, device: Device, options: Options, out: *std.Io.Writer) !void {
    const info = try device.profileInfo();
    if (info.sector_size != core.profile.sector_size) return error.UnsupportedLayout;
    const active = try profileSlot(try device.currentProfile());
    var summaries: std.ArrayList(ProfileSummary) = .empty;
    for (1..@as(usize, info.count) + 1) |number| {
        const sector: u8 = @intCast(number);
        const bytes = try device.readSector(allocator, sector);
        defer allocator.free(bytes);
        core.profile.validate(bytes) catch {
            try summaries.append(allocator, .{
                .sector = sector,
                .active = active == sector,
                .dpi_x = 0,
                .dpi_y = 0,
                .rate_hz = 0,
                .crc_valid = false,
            });
            continue;
        };
        const dpi = try core.profile.dpi(bytes);
        try summaries.append(allocator, .{
            .sector = sector,
            .active = active == sector,
            .dpi_x = dpi.x,
            .dpi_y = dpi.y,
            .rate_hz = try core.profile.reportRate(bytes),
            .crc_valid = true,
        });
    }
    if (options.json) return writeJson(out, summaries.items);
    for (summaries.items) |item| {
        try out.print("{s} profile {d}: {d}x{d} DPI, {d} Hz, CRC {s}\n", .{
            if (item.active) "*" else " ", item.sector,                             item.dpi_x, item.dpi_y,
            item.rate_hz,                  if (item.crc_valid) "ok" else "INVALID",
        });
    }
}

fn showProfile(out: *std.Io.Writer, sector: u8, bytes: []const u8, json: bool) !void {
    const dpi = try core.profile.dpi(bytes);
    const rate = try core.profile.reportRate(bytes);
    const value = .{ .sector = sector, .dpi_x = dpi.x, .dpi_y = dpi.y, .rate_hz = rate, .crc_valid = true };
    if (json) return writeJson(out, value);
    try out.print("profile {d}: {d} x {d} DPI, {d} Hz, CRC ok\n", .{ sector, dpi.x, dpi.y, rate });
}

fn selectedProfile(device: Device, requested: ?u8) !u8 {
    const sector = requested orelse try profileSlot(try device.currentProfile());
    try validateProfileNumber(device, sector);
    return sector;
}

/// Factory profiles live in ROM bank 0x01xx while writable profiles live in
/// RAM bank 0x00xx. Both use the low byte as the user-visible profile slot.
fn profileSlot(sector: u16) !u8 {
    const slot: u8 = @intCast(sector & 0xff);
    if (slot == 0) return error.InvalidProfile;
    return slot;
}

fn validateProfileNumber(device: Device, sector: u8) !void {
    const info = try device.profileInfo();
    if (sector < 1 or sector > info.count) return error.InvalidProfile;
}

fn saveBackup(io: std.Io, sector: u8, bytes: []const u8, out: *std.Io.Writer) !void {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "px2-profile-{d}.backup.bin", .{sector});
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    try out.print("backup saved to {s}\n", .{name});
}

fn measureRate(io: std.Io, candidate: Candidate, options: Options, out: *std.Io.Writer) !void {
    var raw = try core.hidraw.HidRaw.open(io, candidate.path);
    defer raw.close();
    const transport = raw.transport();
    try out.writeAll("Move the mouse continuously for two seconds...\n");
    const start = std.Io.Clock.awake.now(io);
    var count: usize = 0;
    var buffer: [64]u8 = undefined;
    while (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000) {
        const n = transport.read(&buffer, 100) catch |err| switch (err) {
            error.TimedOut => continue,
            else => return err,
        };
        if (n > 0 and buffer[0] != core.hidpp.short_report_id and buffer[0] != core.hidpp.long_report_id)
            count += 1;
    }
    const hz: usize = count / 2;
    if (options.json) return writeJson(out, .{ .samples = count, .seconds = 2, .measured_hz = hz });
    try out.print("approximately {d} Hz ({d} reports / 2 seconds)\n", .{ hz, count });
}

fn printHits(out: *std.Io.Writer, name: []const u8, config: HitsConfig) !void {
    try out.print("{s}: actuation {d}, rapid {d}, haptics {d}\n", .{
        name, config.actuation, config.rapid_trigger, config.haptics,
    });
}

fn buttonName(button: u8) []const u8 {
    return if (button == 0) "left" else "right";
}

fn parseConnection(value: []const u8) !core.discovery.Filter {
    if (eql(value, "auto")) return .auto;
    if (eql(value, "direct")) return .direct;
    if (eql(value, "receiver")) return .receiver;
    return error.InvalidConnection;
}

fn explainConnectError(out: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.DeviceNotFound => try out.writeAll("No responsive PRO X2 SUPERSTRIKE was found. Try `px2 list` or `px2 doctor --device /dev/hidrawN`.\n"),
        error.PermissionDenied => try out.writeAll("Permission denied opening hidraw. Install the supplied udev rule, reload udev, and reconnect the device.\n"),
        else => try out.print("Unable to connect to the mouse: {s}\n", .{@errorName(err)}),
    }
}

fn writeJson(out: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\px2 — Logitech PRO X2 SUPERSTRIKE control CLI
        \\
        \\Usage:
        \\  px2 list [--json]
        \\  px2 status [--json]
        \\  px2 doctor [--json]
        \\  px2 get hits|dpi|rate|profiles [--json]
        \\  px2 set hits left|right|both [--actuation N] [--rapid N] [--haptics N]
        \\  px2 set dpi DPI [--profile N] [--dry-run]
        \\  px2 set rate HZ [--profile N] [--dry-run]
        \\  px2 profile list|show N|activate N
        \\  px2 profile export N FILE
        \\  px2 profile apply N FILE [--dry-run]
        \\  px2 rate measure
        \\
        \\Global options:
        \\  --connection auto|direct|receiver
        \\  --device /dev/hidrawN
        \\  --timeout MILLISECONDS
        \\  --json
        \\  --dry-run
        \\
    );
}

test "connection option parsing" {
    try std.testing.expectEqual(core.discovery.Filter.receiver, try parseConnection("receiver"));
    try std.testing.expectError(error.InvalidConnection, parseConnection("bluetooth"));
}

test "ROM and RAM sectors map to the same profile slot" {
    try std.testing.expectEqual(@as(u8, 1), try profileSlot(0x0101));
    try std.testing.expectEqual(@as(u8, 1), try profileSlot(0x0001));
    try std.testing.expectError(error.InvalidProfile, profileSlot(0x0100));
}
