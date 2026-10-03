const std = @import("std");
const core = @import("superstrike");

const Candidate = core.discovery.Candidate;
const Connection = core.discovery.Connection;
const Device = core.device.Device;
const HitsConfig = core.device.HitsConfig;

const json_schema_version: u8 = 1;

const Options = struct {
    json: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
    connection: core.discovery.Filter = .auto,
    device_path: ?[]const u8 = null,
    timeout_ms: u32 = 750,
    profile: ?u8 = null,
    backup_dir: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
    desired: core.state.Desired = .{},
    connection_explicit: bool = false,
    idle_seconds: u32 = 30,
    trace: bool = false,
};

pub fn run(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const parsed = try parseArgs(allocator, args[1..]);
    var options = parsed.options;
    if (options.state_dir == null) {
        if (init.environ_map.get("XDG_STATE_HOME")) |state_home|
            options.state_dir = try std.fs.path.join(allocator, &.{ state_home, "px2" })
        else if (init.environ_map.get("HOME")) |home|
            options.state_dir = try std.fs.path.join(allocator, &.{ home, ".local/state/px2" })
        else
            return error.MissingStateDirectory;
    }
    if (options.backup_dir == null) {
        if (init.environ_map.get("XDG_STATE_HOME")) |state_home|
            options.backup_dir = try std.fs.path.join(allocator, &.{ state_home, "px2/backups" })
        else if (init.environ_map.get("HOME")) |home|
            options.backup_dir = try std.fs.path.join(allocator, &.{ home, ".local/state/px2/backups" })
        else
            options.backup_dir = "px2-backups";
    }
    const words = parsed.words;

    return runParsed(init, allocator, options, words, stdout, stderr) catch |err| {
        if (options.json) try writeJson(stdout, .{
            .schema_version = json_schema_version,
            .ok = false,
            .@"error" = @errorName(err),
        });
        return err;
    };
}

fn runParsed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    initial_options: Options,
    words: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var options = initial_options;
    if (words.len == 0 or eql(words[0], "help") or eql(words[0], "--help")) {
        try printHelp(stdout);
        return;
    }

    if (eql(words[0], "list")) {
        return list(init.io, allocator, options, stdout);
    }
    if (eql(words[0], "watch")) {
        if (words.len == 2 and eql(words[1], "status")) return watchStatus(init.io, allocator, options, stdout);
        if (words.len != 1 or options.dry_run or options.json or options.profile != null) return error.InvalidOption;
        return core.watch.run(init.io, std.heap.page_allocator, options.state_dir.?, .{
            .connection = if (options.connection_explicit) options.connection else null,
            .device_path = options.device_path,
            .timeout_ms = options.timeout_ms,
            .idle_ms = @as(i64, options.idle_seconds) * 1000,
            .trace = options.trace,
        }, stderr);
    }
    if (eql(words[0], "rate") and words.len >= 2 and eql(words[1], "measure"))
        return measureRate(init.io, allocator, options.device_path, options, stdout);

    const store = stateStore(init.io, allocator, options);
    const transaction = try store.acquire("device.lock", true);
    defer transaction.close(init.io);
    options.desired = try store.load();
    if (!options.connection_explicit) options.connection = options.desired.connection;

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
        return status(allocator, device, connected.candidate, options, stdout);
    if (eql(words[0], "snapshot"))
        return snapshot(allocator, device, connected.candidate, options, stdout);
    if (eql(words[0], "doctor"))
        return doctor(init.io, allocator, device, connected.candidate, options, stdout);
    if (eql(words[0], "get"))
        return get(allocator, device, words, options, stdout);
    if (eql(words[0], "set"))
        return set(init.io, allocator, device, words, options, stdout);
    if (eql(words[0], "profile"))
        return profileCommand(init.io, allocator, device, words, options, stdout);
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
            options.connection_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--connection=")) {
            options.connection = try parseConnection(arg[13..]);
            options.connection_explicit = true;
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
        } else if (eql(arg, "--backup-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.backup_dir = args[i];
        } else if (eql(arg, "--state-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.state_dir = args[i];
        } else if (eql(arg, "--idle-seconds")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            options.idle_seconds = try std.fmt.parseInt(u32, args[i], 10);
            if (options.idle_seconds == 0 or options.idle_seconds > 86400) return error.InvalidOption;
        } else if (eql(arg, "--trace")) {
            options.trace = true;
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

fn status(allocator: std.mem.Allocator, device: Device, candidate: Candidate, options: Options, out: *std.Io.Writer) !void {
    const battery = try device.battery();
    const left = try device.hitsConfig(0);
    const right = try device.hitsConfig(1);
    const dpi = try device.currentDpi();
    const rate = try device.currentRate();
    const inventory = try inspectProfiles(allocator, device);
    const active_sector = inventory.current_sector;
    const active_profile = try intendedProfileSlot(inventory, options);
    const effective = try profileBySlot(inventory, active_profile);
    const value = .{
        .schema_version = json_schema_version,
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
        .desired_profile = options.desired.slot(),
        .effective_source = "saved_profile",
        .effective_verified = false,
        .effective_dpi_x = effective.dpi_x,
        .effective_dpi_y = effective.dpi_y,
        .effective_rate_hz = effective.rate_hz,
        .left_hits = left,
        .right_hits = right,
    };
    if (options.json) return writeJson(out, value);
    try out.print(
        \\Device: {s} ({s}, index 0x{x:0>2})
        \\Path: {s}
        \\Battery: {d}%{s}
        \\Selected profile: {d} (sector 0x{x:0>4})
        \\Reported DPI: {d} x {d} (firmware may return a stale value)
        \\Reported rate: {d} Hz (firmware may return a stale value)
        \\Saved profile DPI: {d} x {d}
        \\Saved profile rate: {d} Hz
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
        effective.dpi_x,
        effective.dpi_y,
        effective.rate_hz,
        left.actuation,
        left.rapid_trigger,
        left.haptics,
        right.actuation,
        right.rapid_trigger,
        right.haptics,
    });
}

fn snapshot(allocator: std.mem.Allocator, device: Device, candidate: Candidate, options: Options, out: *std.Io.Writer) !void {
    const battery = try device.battery();
    const hits_caps = try device.hitsCapabilities();
    const left = try device.hitsConfig(0);
    const right = try device.hitsConfig(1);
    const reported_dpi = try device.currentDpi();
    const reported_rate = try device.currentRate();
    const dpi_range = try device.dpiRange();
    const rate_mask = try device.supportedRateMask();
    const inventory = try inspectProfiles(allocator, device);
    const onboard_mode = try device.onboardMode();
    const active_sector = inventory.current_sector;
    const active_profile = try intendedProfileSlot(inventory, options);
    const effective = try profileBySlot(inventory, active_profile);

    var rates: std.ArrayList(u16) = .empty;
    for ([_]u16{ 125, 250, 500, 1000, 2000, 4000, 8000 }, 0..) |hz, index| {
        if ((rate_mask & (@as(u16, 1) << @intCast(index))) != 0)
            try rates.append(allocator, hz);
    }

    const value = .{
        .schema_version = json_schema_version,
        .device = .{
            .path = candidate.path,
            .name = candidate.name,
            .connection = candidate.connection,
            .device_index = device.session.device_index,
        },
        .battery = .{
            .percent = battery.percent,
            .charging = battery.charging(),
            .charging_state = battery.charging_state,
        },
        .active_profile = active_profile,
        .active_sector = active_sector,
        .onboard_mode = onboard_mode,
        .desired_profile = options.desired.slot(),
        .saved = .{ .dpi_x = effective.dpi_x, .dpi_y = effective.dpi_y, .rate_hz = effective.rate_hz },
        .profile_info = inventory.info,
        .controls = .{ .ram = inventory.ram_control, .rom = inventory.rom_control },
        .reported = .{
            .dpi_x = reported_dpi.x,
            .dpi_y = reported_dpi.y,
            .rate_hz = reported_rate,
        },
        .effective = .{
            .dpi_x = effective.dpi_x,
            .dpi_y = effective.dpi_y,
            .rate_hz = effective.rate_hz,
            .source = "saved_profile",
            .verified = false,
        },
        .supported = .{
            .dpi = dpi_range,
            .rate_mask = rate_mask,
            .rates_hz = rates.items,
        },
        .hits = .{
            .capabilities = hits_caps,
            .left = left,
            .right = right,
        },
        .profiles = inventory.profiles,
    };
    if (options.json) return writeJson(out, value);
    try out.print("{s}: {d}%{s}, profile {d}, {d} DPI, {d} Hz\n", .{
        candidate.name,
        battery.percent,
        if (battery.charging()) " (charging)" else "",
        active_profile,
        effective.dpi_x,
        effective.rate_hz,
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
        const inventory = try inspectProfiles(allocator, device);
        const active = try intendedProfileSlot(inventory, options);
        const active_profile = try profileBySlot(inventory, active);
        if (!active_profile.crc_valid) return error.NoValidProfile;
        const bytes = try device.readSectorValidated(allocator, active_profile.source_sector);
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
    if (eql(words[1], "hits")) return setHits(io, allocator, device, words, options, out);
    if (eql(words[1], "dpi") or eql(words[1], "rate")) {
        if (words.len < 3) return error.MissingValue;
        const numeric = try std.fmt.parseInt(u16, words[2], 10);
        const slot = try selectedProfile(device, options.profile orelse options.desired.slot());
        const inventory = try inspectProfiles(allocator, device);
        const selected = try profileBySlot(inventory, slot);
        if (!selected.editable) return error.ProfileNeedsInitialization;
        const bytes = try device.readSectorValidated(allocator, selected.writable_sector);
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
        const backup = if (!options.dry_run) try saveBackupAt(io, allocator, options.backup_dir.?, slot, bytes) else null;
        if (setting_dpi)
            try core.profile.setDpi(bytes, numeric)
        else
            try core.profile.setReportRate(bytes, numeric);

        if (options.dry_run) {
            if (options.json) return writeJson(out, .{
                .schema_version = json_schema_version,
                .ok = true,
                .action = if (setting_dpi) "set_dpi" else "set_rate",
                .dry_run = true,
                .profile = slot,
                .value = numeric,
            });
            try out.print("dry run: profile {d} would be updated to {s} {d}\n", .{ slot, words[1], numeric });
            return;
        }
        try device.writeSector(allocator, selected.writable_sector, bytes);
        const reloaded = try intendedProfileSlot(inventory, options) == slot;
        if (reloaded) try device.reloadProfile(
            io,
            selected.writable_sector,
            try reloadFallbackSector(inventory, selected.writable_sector),
        );
        // Solaar applies the 0x2202/0x8061 live setters with onboard profiles
        // disabled. Keep the profile write for persistence, then mirror both
        // saved values into host mode when this is the active profile.
        const live_settings_applied = reloaded;
        if (live_settings_applied) {
            try mirrorProfileToHost(io, device, bytes);
            try core.restore.hits(device, options.desired.hits[slot - 1]);
            try rememberProfile(io, allocator, options, selected.writable_sector);
        }
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .ok = true,
            .action = if (setting_dpi) "set_dpi" else "set_rate",
            .dry_run = false,
            .profile = slot,
            .value = numeric,
            .reloaded = reloaded,
            .live_settings_applied = live_settings_applied,
            .onboard_mode = try device.onboardMode(),
            .active_sector = try device.currentProfile(),
            .backup = backup.?,
        });
        if (backup.?.created) try out.print("backup saved to {s}\n", .{backup.?.path});
        try out.print("profile {d} updated: {s} {d}\n", .{ slot, words[1], numeric });
        return;
    }
    return error.InvalidSubcommand;
}

fn mirrorProfileToHost(io: std.Io, device: Device, bytes: []const u8) !void {
    return core.restore.mirror(io, device, bytes);
}

fn setHits(io: std.Io, allocator: std.mem.Allocator, device: Device, words: []const []const u8, options: Options, out: *std.Io.Writer) !void {
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

    const inventory = try inspectProfiles(allocator, device);
    const slot = try intendedProfileSlot(inventory, options);
    if (options.profile) |requested| if (requested != slot) return error.ProfileNotActive;
    const selected = try profileBySlot(inventory, slot);
    var saved_state = options.desired;
    if (!selected.crc_valid) return error.NoValidProfile;
    saved_state.sector = selected.source_sector;
    saved_state.connection = options.connection;
    var left_result: ?HitsConfig = null;
    var right_result: ?HitsConfig = null;
    var button = first;
    while (button <= last) : (button += 1) {
        const current = try device.hitsConfig(button);
        const desired: HitsConfig = .{
            .button = button,
            .actuation = actuation orelse current.actuation,
            .rapid_trigger = rapid orelse current.rapid_trigger,
            .haptics = haptics orelse current.haptics,
            .sensitivity_flag = current.sensitivity_flag,
        };
        if (options.dry_run) {
            if (button == 0) left_result = desired else right_result = desired;
            if (!options.json)
                try out.print("dry run: {s}: actuation {d}->{d}, rapid {d}->{d}, haptics {d}->{d}\n", .{
                    buttonName(button),    current.actuation, desired.actuation, current.rapid_trigger,
                    desired.rapid_trigger, current.haptics,   desired.haptics,
                });
        } else {
            const updated = try device.setHits(button, actuation, rapid, haptics);
            if (actuation) |v| if (updated.actuation != v) return error.HitsVerificationFailed;
            if (rapid) |v| if (updated.rapid_trigger != v) return error.HitsVerificationFailed;
            if (haptics) |v| if (updated.haptics != v) return error.HitsVerificationFailed;
            const saved = &saved_state.hits[slot - 1][button];
            if (actuation) |v| saved.actuation = v;
            if (rapid) |v| saved.rapid_trigger = v;
            if (haptics) |v| saved.haptics = v;
            if (button == 0) left_result = updated else right_result = updated;
            if (!options.json) try printHits(out, buttonName(button), updated);
        }
        if (button == 255) break;
    }
    if (!options.dry_run) try stateStore(io, allocator, options).save(&saved_state);
    if (options.json) return writeJson(out, .{
        .schema_version = json_schema_version,
        .ok = true,
        .action = "set_hits",
        .dry_run = options.dry_run,
        .target = words[2],
        .left = left_result,
        .right = right_result,
    });
}

fn profileCommand(io: std.Io, allocator: std.mem.Allocator, device: Device, words: []const []const u8, options: Options, out: *std.Io.Writer) !void {
    if (words.len < 2) return error.MissingSubcommand;
    if (eql(words[1], "list")) return listProfiles(allocator, device, options, out);
    if (eql(words[1], "inspect")) {
        const inventory = try inspectProfiles(allocator, device);
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .profile_info = inventory.info,
            .current_sector = inventory.current_sector,
            .controls = .{ .ram = inventory.ram_control, .rom = inventory.rom_control },
            .profiles = inventory.profiles,
        });
        try printProfileInventory(out, inventory);
        return;
    }
    if (eql(words[1], "inspect-sector")) {
        if (words.len < 3) return error.MissingProfile;
        const sector = try std.fmt.parseInt(u16, words[2], 0);
        const inspected = try device.inspectSector(allocator, sector);
        defer allocator.free(inspected.bytes);
        return writeJson(out, sectorDiagnostic(sector, inspected));
    }
    if (words.len < 3) return error.MissingProfile;
    const slot = try std.fmt.parseInt(u8, words[2], 10);
    try validateProfileNumber(device, slot);
    const inventory = try inspectProfiles(allocator, device);
    const selected = try profileBySlot(inventory, slot);

    if (eql(words[1], "initialize")) {
        var from_factory = false;
        for (words[3..]) |word| {
            if (eql(word, "--from-factory")) from_factory = true else return error.InvalidOption;
        }
        if (!from_factory) return error.FactorySourceRequired;
        return initializeProfile(io, allocator, device, inventory, selected, options, out);
    }

    if (eql(words[1], "show")) {
        if (!selected.crc_valid) return error.NoValidProfile;
        const bytes = try device.readSectorValidated(allocator, selected.source_sector);
        defer allocator.free(bytes);
        return showProfile(out, slot, selected.source_sector, bytes, options.json);
    }
    if (eql(words[1], "activate")) {
        if (!selected.crc_valid) return error.NoValidProfile;
        if (!selected.initialized and (selected.source_sector & 0xff) != slot)
            return error.ProfileNeedsInitialization;
        if (options.dry_run) {
            if (options.json) return writeJson(out, .{
                .schema_version = json_schema_version,
                .ok = true,
                .action = "activate_profile",
                .dry_run = true,
                .profile = slot,
                .source_sector = selected.source_sector,
            });
            try out.print("dry run: profile {d} (sector 0x{x:0>4}) would be activated\n", .{ slot, selected.source_sector });
            return;
        }
        try device.activateProfile(selected.source_sector);
        const bytes = try device.readSectorValidated(allocator, selected.source_sector);
        defer allocator.free(bytes);
        try mirrorProfileToHost(io, device, bytes);
        try core.restore.hits(device, options.desired.hits[slot - 1]);
        try rememberProfile(io, allocator, options, selected.source_sector);
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .ok = true,
            .action = "activate_profile",
            .dry_run = false,
            .profile = slot,
            .source_sector = selected.source_sector,
            .onboard_mode = try device.onboardMode(),
        });
        try out.print("profile {d} activated from sector 0x{x:0>4}\n", .{ slot, selected.source_sector });
        return;
    }
    if (eql(words[1], "export")) {
        if (words.len < 4) return error.MissingPath;
        if (!selected.crc_valid) return error.NoValidProfile;
        const bytes = try device.readSectorValidated(allocator, selected.source_sector);
        defer allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = words[3], .data = bytes });
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .ok = true,
            .action = "export_profile",
            .profile = slot,
            .source_sector = selected.source_sector,
            .path = words[3],
        });
        try out.print("profile {d} exported to {s}\n", .{ slot, words[3] });
        return;
    }
    if (eql(words[1], "apply")) {
        if (words.len < 4) return error.MissingPath;
        if (!selected.editable) return error.ProfileNeedsInitialization;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, words[3], allocator, .limited(4096));
        try core.profile.validate(bytes);
        const original = try device.readSectorValidated(allocator, selected.writable_sector);
        defer allocator.free(original);
        if (options.dry_run) {
            if (options.json) return writeJson(out, .{
                .schema_version = json_schema_version,
                .ok = true,
                .action = "apply_profile",
                .dry_run = true,
                .profile = slot,
                .path = words[3],
            });
            try out.print("dry run: {s} would be applied to profile {d}\n", .{ words[3], slot });
            return;
        }
        const backup = try saveBackupAt(io, allocator, options.backup_dir.?, slot, original);
        try device.writeSector(allocator, selected.writable_sector, bytes);
        const reloaded = try intendedProfileSlot(inventory, options) == slot;
        if (reloaded) try device.reloadProfile(
            io,
            selected.writable_sector,
            try reloadFallbackSector(inventory, selected.writable_sector),
        );
        if (reloaded) {
            try mirrorProfileToHost(io, device, bytes);
            try core.restore.hits(device, options.desired.hits[slot - 1]);
            try rememberProfile(io, allocator, options, selected.writable_sector);
        }
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .ok = true,
            .action = "apply_profile",
            .dry_run = false,
            .profile = slot,
            .path = words[3],
            .reloaded = reloaded,
            .active_sector = try device.currentProfile(),
            .backup = backup,
        });
        if (backup.created) try out.print("backup saved to {s}\n", .{backup.path});
        try out.print("{s} applied and verified as profile {d}\n", .{ words[3], slot });
        return;
    }
    return error.InvalidSubcommand;
}

const SectorDiagnostic = struct {
    sector: u16,
    health: core.profile.SectorHealth,
    attempts: u8,
    stored_crc: u16,
    computed_crc: u16,
    first_bytes: [16]u8,
};

const ControlSummary = struct {
    diagnostic: SectorDiagnostic,
    entries: []const core.profile.ControlEntry,
};

const ProfileStorage = enum { ram, rom, unavailable };

const ProfileSummary = struct {
    slot: u8,
    source_sector: u16,
    writable_sector: u8,
    storage: ProfileStorage,
    initialized: bool,
    editable: bool,
    editable_reason: ?[]const u8,
    enabled: bool,
    active: bool,
    dpi_x: u16,
    dpi_y: u16,
    rate_hz: u16,
    crc_valid: bool,
    ram_health: core.profile.SectorHealth,
    rom_health: core.profile.SectorHealth,
};

const ProfileInventory = struct {
    info: core.device.ProfileInfo,
    current_sector: u16,
    ram_control: ControlSummary,
    rom_control: ControlSummary,
    profiles: []const ProfileSummary,
};

fn sectorDiagnostic(sector: u16, inspected: core.device.SectorInspection) SectorDiagnostic {
    var first: [16]u8 = @splat(0);
    @memcpy(first[0..@min(first.len, inspected.bytes.len)], inspected.bytes[0..@min(first.len, inspected.bytes.len)]);
    return .{
        .sector = sector,
        .health = inspected.health,
        .attempts = inspected.attempts,
        .stored_crc = inspected.stored_crc,
        .computed_crc = inspected.computed_crc,
        .first_bytes = first,
    };
}

fn inspectControl(allocator: std.mem.Allocator, device: Device, sector: u16, profile_count: u8) !ControlSummary {
    if ((sector & 0xff00) != 0) {
        var last_diagnostic: SectorDiagnostic = undefined;
        for (1..9) |attempt| {
            const bytes = try device.readSector(allocator, sector);
            defer allocator.free(bytes);
            const inspected: core.device.SectorInspection = .{
                .bytes = bytes,
                .attempts = @intCast(attempt),
                .health = core.profile.health(bytes),
                .stored_crc = core.profile.storedCrc(bytes) catch 0,
                .computed_crc = core.profile.crc16CcittFalse(bytes[0 .. bytes.len - 2]),
            };
            last_diagnostic = sectorDiagnostic(sector, inspected);
            var entries_buffer: [8]core.profile.ControlEntry = undefined;
            const entries = core.profile.parseControl(bytes, profile_count, &entries_buffer) catch continue;
            if (entries.len == 0) continue;
            last_diagnostic.health = .valid;
            return .{
                .diagnostic = last_diagnostic,
                .entries = try allocator.dupe(core.profile.ControlEntry, entries),
            };
        }
        return .{ .diagnostic = last_diagnostic, .entries = &.{} };
    }
    const inspected = try device.inspectSector(allocator, sector);
    defer allocator.free(inspected.bytes);
    var entries_buffer: [8]core.profile.ControlEntry = undefined;
    const diagnostic = sectorDiagnostic(sector, inspected);
    const entries = if (inspected.health == .valid)
        core.profile.parseControl(inspected.bytes, profile_count, &entries_buffer) catch &.{}
    else
        &.{};
    return .{
        .diagnostic = diagnostic,
        .entries = try allocator.dupe(core.profile.ControlEntry, entries),
    };
}

fn entryForSlot(control: ControlSummary, slot: u8) ?core.profile.ControlEntry {
    for (control.entries) |entry| if (entry.slot == slot) return entry;
    return null;
}

fn inspectProfiles(allocator: std.mem.Allocator, device: Device) !ProfileInventory {
    const info = try device.profileInfo();
    if (info.count == 0 or info.count > 8 or info.sector_size != core.profile.sector_size)
        return error.UnsupportedLayout;
    const current = try device.currentProfile();
    const ram_control = try inspectControl(allocator, device, 0x0000, info.count);
    const rom_control = try inspectControl(allocator, device, 0x0100, info.count);
    const known_layout = info.memory_model == 1 and info.format == 8 and info.sector_size == core.profile.sector_size;

    var mapped_factory_sector: u16 = 0;
    var factory_bytes: ?[]u8 = null;
    var factory_health: core.profile.SectorHealth = .invalid_crc;
    if (rom_control.entries.len != 0) {
        const factory_sector = rom_control.entries[0].sector;
        mapped_factory_sector = if ((factory_sector & 0xff00) != 0)
            factory_sector
        else
            @as(u16, 0x0100) | factory_sector;
        if (device.inspectSector(allocator, mapped_factory_sector)) |factory| {
            factory_bytes = factory.bytes;
            factory_health = factory.health;
            if (factory_health == .invalid_crc) {
                const factory_dpi = core.profile.dpi(factory.bytes) catch null;
                const factory_rate = core.profile.reportRate(factory.bytes) catch null;
                if (factory_dpi != null and factory_rate != null) factory_health = .valid;
            }
        } else |_| {}
    }
    defer if (factory_bytes) |bytes| allocator.free(bytes);

    var summaries: std.ArrayList(ProfileSummary) = .empty;
    for (1..@as(usize, info.count) + 1) |number| {
        const slot: u8 = @intCast(number);
        const ram_entry = entryForSlot(ram_control, slot);
        const rom_entry = entryForSlot(rom_control, slot);
        const writable_sector: u8 = if (ram_entry) |entry| @intCast(entry.sector & 0xff) else slot;
        var ram = try device.inspectSector(allocator, writable_sector);
        if (ram.health != .valid and current == writable_sector) {
            allocator.free(ram.bytes);
            ram = try device.inspectSector(allocator, writable_sector);
        }
        defer allocator.free(ram.bytes);

        const initialized = ram.health == .valid;
        const source_bytes = if (initialized) ram.bytes else if (factory_health == .valid) factory_bytes else null;
        const storage: ProfileStorage = if (initialized) .ram else if (factory_health == .valid) .rom else .unavailable;
        const source_sector: u16 = switch (storage) {
            .ram => writable_sector,
            .rom => mapped_factory_sector,
            .unavailable => 0,
        };
        var dpi_x: u16 = 0;
        var dpi_y: u16 = 0;
        var rate_hz: u16 = 0;
        var decoded = false;
        if (source_bytes) |bytes| {
            if (core.profile.dpi(bytes)) |dpi| {
                dpi_x = dpi.x;
                dpi_y = dpi.y;
                rate_hz = core.profile.reportRate(bytes) catch 0;
                decoded = rate_hz != 0;
            } else |_| {}
        }
        const editable = initialized and known_layout and decoded;
        const reason: ?[]const u8 = if (editable)
            null
        else if (!known_layout)
            "unsupported_layout"
        else if (ram.health == .blank and factory_health == .valid)
            "needs_initialization"
        else if (ram.health == .invalid_crc and factory_health == .valid)
            "ram_invalid_crc"
        else if (factory_health != .valid)
            "no_valid_factory_profile"
        else
            "profile_decode_failed";
        const enabled = if (ram_entry) |entry|
            entry.enabled
        else if (rom_entry) |entry|
            entry.enabled
        else
            slot == 1;

        try summaries.append(allocator, .{
            .slot = slot,
            .source_sector = source_sector,
            .writable_sector = writable_sector,
            .storage = storage,
            .initialized = initialized,
            .editable = editable,
            .editable_reason = reason,
            .enabled = enabled,
            .active = (current & 0xff) == slot or (current == 0 and enabled),
            .dpi_x = dpi_x,
            .dpi_y = dpi_y,
            .rate_hz = rate_hz,
            .crc_valid = source_bytes != null and decoded,
            .ram_health = ram.health,
            .rom_health = factory_health,
        });
    }
    return .{
        .info = info,
        .current_sector = current,
        .ram_control = ram_control,
        .rom_control = rom_control,
        .profiles = try summaries.toOwnedSlice(allocator),
    };
}

fn profileBySlot(inventory: ProfileInventory, slot: u8) !ProfileSummary {
    for (inventory.profiles) |item| if (item.slot == slot) return item;
    return error.InvalidProfile;
}

fn activeProfileSlot(inventory: ProfileInventory) !u8 {
    if (inventory.current_sector != 0) return profileSlot(inventory.current_sector);
    // Solaar represents disabled onboard profiles as sector 0. In host mode,
    // retain the enabled onboard slot as the persistent profile mirrored to
    // the live 0x2202/0x8061 settings.
    for (inventory.profiles) |item| if (item.enabled) return item.slot;
    if (inventory.profiles.len != 0) return inventory.profiles[0].slot;
    return error.InvalidProfile;
}

fn intendedProfileSlot(inventory: ProfileInventory, options: Options) !u8 {
    if (options.desired.slot()) |slot| {
        _ = try profileBySlot(inventory, slot);
        return slot;
    }
    return activeProfileSlot(inventory);
}

fn stateStore(io: std.Io, allocator: std.mem.Allocator, options: Options) core.state.Store {
    return .{ .io = io, .allocator = allocator, .directory = options.state_dir.? };
}

fn rememberProfile(io: std.Io, allocator: std.mem.Allocator, options: Options, sector: u16) !void {
    var desired = options.desired;
    desired.sector = sector;
    desired.connection = options.connection;
    try stateStore(io, allocator, options).save(&desired);
}

fn watchStatus(io: std.Io, allocator: std.mem.Allocator, options: Options, out: *std.Io.Writer) !void {
    const store = stateStore(io, allocator, options);
    var running = false;
    const probe = store.acquire("watch.lock", false) catch |err| switch (err) {
        error.AlreadyRunning => blk: {
            running = true;
            break :blk null;
        },
        else => return err,
    };
    if (probe) |file| file.close(io);
    var state_error: ?[]const u8 = null;
    const desired = store.load() catch |err| blk: {
        state_error = @errorName(err);
        break :blk core.state.Desired{};
    };
    const last_status = try store.read(core.state.WatchStatus, "watch-status.json");
    if (options.json) return writeJson(out, .{
        .schema_version = json_schema_version,
        .running = running,
        .state_directory = options.state_dir.?,
        .state_error = state_error,
        .desired = desired,
        .last_status = last_status,
    });
    try out.print("Watcher: {s}\nState: {s}\n", .{ if (running) "running" else "stopped", options.state_dir.? });
    if (state_error) |err| try out.print("State error: {s}\n", .{err});
    if (desired.slot()) |slot|
        try out.print("Desired profile: {d} ({s})\n", .{ slot, @tagName(desired.connection) })
    else
        try out.writeAll("No saved selection. Run `px2 profile activate N` once.\n");
    if (last_status) |s| {
        try out.print("Last recorded phase: {s}\n", .{@tagName(s.phase)});
        if (s.last_restore_ms) |ms| try out.print("Last successful restoration: {d} ms since epoch (live values unverified)\n", .{ms});
        if (s.last_error) |err| try out.print("Last error: {s}\n", .{err});
    }
}

fn factoryProfileSector(inventory: ProfileInventory) !u16 {
    if (inventory.rom_control.entries.len == 0) return error.NoValidFactoryProfile;
    const sector = inventory.rom_control.entries[0].sector;
    return if ((sector & 0xff00) != 0) sector else @as(u16, 0x0100) | sector;
}

fn reloadFallbackSector(inventory: ProfileInventory, target: u16) !u16 {
    for (inventory.profiles) |item| {
        if (item.initialized and item.writable_sector != target)
            return item.writable_sector;
    }
    return factoryProfileSector(inventory);
}

fn initializeProfile(
    io: std.Io,
    allocator: std.mem.Allocator,
    device: Device,
    inventory: ProfileInventory,
    selected: ProfileSummary,
    options: Options,
    out: *std.Io.Writer,
) !void {
    if (inventory.info.memory_model != 1 or inventory.info.sector_size != core.profile.sector_size)
        return error.UnsupportedLayout;
    if (selected.initialized) {
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .ok = true,
            .action = "initialize_profile",
            .profile = selected.slot,
            .changed = false,
            .editable = selected.editable,
        });
        try out.print("profile {d} is already initialized in writable RAM\n", .{selected.slot});
        return;
    }
    if (selected.rom_health != .valid or selected.source_sector < 0x0100)
        return error.NoValidFactoryProfile;

    const factory_raw = try device.readSector(allocator, selected.source_sector);
    defer allocator.free(factory_raw);
    _ = try core.profile.dpi(factory_raw);
    _ = try core.profile.reportRate(factory_raw);
    const factory = try allocator.dupe(u8, factory_raw);
    defer allocator.free(factory);
    try core.profile.refreshCrc(factory);
    const ram_before = try device.readSector(allocator, selected.writable_sector);
    defer allocator.free(ram_before);
    const ram_control_before = try device.readSector(allocator, 0x0000);
    defer allocator.free(ram_control_before);
    const rom_control = try device.readSector(allocator, 0x0100);
    defer allocator.free(rom_control);

    const new_control = try allocator.alloc(u8, core.profile.sector_size);
    defer allocator.free(new_control);
    const needs_control = inventory.ram_control.diagnostic.health != .valid;
    if (needs_control) try core.profile.controlForRam(rom_control, inventory.info.count, new_control);

    if (options.dry_run) {
        if (options.json) return writeJson(out, .{
            .schema_version = json_schema_version,
            .ok = true,
            .action = "initialize_profile",
            .dry_run = true,
            .profile = selected.slot,
            .source_sector = selected.source_sector,
            .writable_sector = selected.writable_sector,
            .would_initialize_control = needs_control,
        });
        try out.print("dry run: profile {d} would be cloned from factory sector 0x{x:0>4} to writable sector 0x{x:0>4}; control initialization: {s}\n", .{
            selected.slot,
            selected.source_sector,
            selected.writable_sector,
            if (needs_control) "yes" else "no",
        });
        return;
    }

    const backup_dir = try createBackupTransaction(io, allocator, options.backup_dir.?, selected.slot);
    try writeBackupFile(io, allocator, backup_dir, "factory-profile-raw.bin", factory_raw);
    try writeBackupFile(io, allocator, backup_dir, "factory-profile-writable.bin", factory);
    try writeBackupFile(io, allocator, backup_dir, "ram-profile-before.bin", ram_before);
    try writeBackupFile(io, allocator, backup_dir, "ram-control-before.bin", ram_control_before);
    try writeBackupFile(io, allocator, backup_dir, "rom-control.bin", rom_control);

    try device.writeSector(allocator, selected.writable_sector, factory);
    if (needs_control) try device.writeControlSector(allocator, new_control);

    const verified = try device.inspectSector(allocator, selected.writable_sector);
    defer allocator.free(verified.bytes);
    if (verified.health != .valid or !std.mem.eql(u8, verified.bytes, factory)) return error.WriteVerificationFailed;

    if (options.json) return writeJson(out, .{
        .schema_version = json_schema_version,
        .ok = true,
        .action = "initialize_profile",
        .dry_run = false,
        .profile = selected.slot,
        .writable_sector = selected.writable_sector,
        .initialized_control = needs_control,
        .backup_dir = backup_dir,
    });
    try out.print("profile {d} initialized and verified; backup saved to {s}\n", .{ selected.slot, backup_dir });
}

fn listProfiles(allocator: std.mem.Allocator, device: Device, options: Options, out: *std.Io.Writer) !void {
    const inventory = try inspectProfiles(allocator, device);
    if (options.json) return writeJson(out, inventory.profiles);
    try printProfileInventory(out, inventory);
}

fn printProfileInventory(out: *std.Io.Writer, inventory: ProfileInventory) !void {
    try out.print("control RAM: {s} ({d} attempts), ROM: {s} ({d} attempts)\n", .{
        @tagName(inventory.ram_control.diagnostic.health),
        inventory.ram_control.diagnostic.attempts,
        @tagName(inventory.rom_control.diagnostic.health),
        inventory.rom_control.diagnostic.attempts,
    });
    for (inventory.profiles) |item| {
        try out.print("{s} profile {d}: {d}x{d} DPI, {d} Hz, {s} sector 0x{x:0>4}, editable {s}", .{
            if (item.active) "*" else " ",
            item.slot,
            item.dpi_x,
            item.dpi_y,
            item.rate_hz,
            @tagName(item.storage),
            item.source_sector,
            if (item.editable) "yes" else "no",
        });
        if (item.editable_reason) |reason| try out.print(" ({s})", .{reason});
        try out.writeByte('\n');
    }
}

fn showProfile(out: *std.Io.Writer, slot: u8, source_sector: u16, bytes: []const u8, json: bool) !void {
    const dpi = try core.profile.dpi(bytes);
    const rate = try core.profile.reportRate(bytes);
    const value = .{ .profile = slot, .source_sector = source_sector, .dpi_x = dpi.x, .dpi_y = dpi.y, .rate_hz = rate, .crc_valid = true };
    if (json) return writeJson(out, value);
    try out.print("profile {d} (sector 0x{x:0>4}): {d} x {d} DPI, {d} Hz, CRC ok\n", .{ slot, source_sector, dpi.x, dpi.y, rate });
}

fn selectedProfile(device: Device, requested: ?u8) !u8 {
    const current = try device.currentProfile();
    const sector = requested orelse if (current == 0) 1 else try profileSlot(current);
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

const BackupResult = struct {
    path: []const u8,
    created: bool,
};

fn saveBackupAt(io: std.Io, allocator: std.mem.Allocator, backup_dir: []const u8, sector: u8, bytes: []const u8) !BackupResult {
    try std.Io.Dir.cwd().createDirPath(io, backup_dir);
    const millis = std.Io.Clock.real.now(io).toMilliseconds();
    const name = try std.fmt.allocPrint(allocator, "px2-profile-{d}-{d}.backup.bin", .{ sector, millis });
    const path = try std.fs.path.join(allocator, &.{ backup_dir, name });
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .path = path, .created = false },
        else => return err,
    };
    return .{ .path = path, .created = true };
}

fn createBackupTransaction(io: std.Io, allocator: std.mem.Allocator, root: []const u8, slot: u8) ![]const u8 {
    const millis = std.Io.Clock.real.now(io).toMilliseconds();
    const leaf = try std.fmt.allocPrint(allocator, "initialize-profile-{d}-{d}", .{ slot, millis });
    const path = try std.fs.path.join(allocator, &.{ root, leaf });
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn writeBackupFile(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .exclusive = true },
    });
}

const InputEvent = extern struct {
    seconds: c_long,
    microseconds: c_long,
    event_type: u16,
    code: u16,
    value: i32,
};

fn measureRate(
    io: std.Io,
    allocator: std.mem.Allocator,
    hidraw_path: ?[]const u8,
    options: Options,
    out: *std.Io.Writer,
) !void {
    const event_path = if (hidraw_path) |path|
        try motionEventPath(io, allocator, path)
    else
        try namedMotionEventPath(io, allocator);
    const event_file = std.Io.Dir.openFileAbsolute(io, event_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
        else => return err,
    };
    defer event_file.close(io);

    try out.writeAll("Move the mouse continuously for two seconds...\n");
    const start = std.Io.Clock.awake.now(io);
    var count: usize = 0;
    var events: [1024]InputEvent = undefined;
    while (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = event_file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 100) == 0) continue;
        if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0)
            return error.Disconnected;

        const bytes = std.mem.asBytes(&events);
        const n = try std.posix.read(event_file.handle, bytes);
        for (events[0 .. n / @sizeOf(InputEvent)]) |event| {
            if (event.event_type == 0 and event.code == 0) count += 1;
        }
    }
    const hz: usize = count / 2;
    if (options.json) return writeJson(out, .{
        .samples = count,
        .seconds = 2,
        .measured_hz = hz,
        .source = "evdev",
        .event_path = event_path,
    });
    try out.print("at least {d} motion frames/s ({d} changed frames / 2 seconds, {s})\n", .{ hz, count, event_path });
}

fn motionEventPath(io: std.Io, allocator: std.mem.Allocator, hidraw_path: []const u8) ![]const u8 {
    const hidraw_name = std.fs.path.basename(hidraw_path);
    if (!std.mem.startsWith(u8, hidraw_name, "hidraw")) return error.MotionEventNotFound;
    const sys_input_path = try std.fmt.allocPrint(
        allocator,
        "/sys/class/hidraw/{s}/device/input",
        .{hidraw_name},
    );
    var input_root = std.Io.Dir.openDirAbsolute(io, sys_input_path, .{ .iterate = true }) catch
        return namedMotionEventPath(io, allocator);
    defer input_root.close(io);

    var inputs = input_root.iterate();
    while (try inputs.next(io)) |input_entry| {
        if (!std.mem.startsWith(u8, input_entry.name, "input")) continue;
        var input_dir = input_root.openDir(io, input_entry.name, .{ .iterate = true }) catch continue;
        defer input_dir.close(io);
        var entries = input_dir.iterate();
        while (try entries.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "event")) continue;
            const capability_path = try std.fmt.allocPrint(
                allocator,
                "/sys/class/input/{s}/device/capabilities/rel",
                .{entry.name},
            );
            const capability = std.Io.Dir.cwd().readFileAlloc(
                io,
                capability_path,
                allocator,
                .limited(256),
            ) catch continue;
            if (!hasRelativeXY(capability)) continue;
            return std.fmt.allocPrint(allocator, "/dev/input/{s}", .{entry.name});
        }
    }
    return namedMotionEventPath(io, allocator);
}

fn namedMotionEventPath(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var input_class = std.Io.Dir.openDirAbsolute(io, "/sys/class/input", .{ .iterate = true }) catch
        return error.MotionEventNotFound;
    defer input_class.close(io);
    var entries = input_class.iterate();
    while (try entries.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "event")) continue;
        const name_path = try std.fmt.allocPrint(
            allocator,
            "/sys/class/input/{s}/device/name",
            .{entry.name},
        );
        const name = std.Io.Dir.cwd().readFileAlloc(io, name_path, allocator, .limited(256)) catch continue;
        if (std.mem.indexOf(u8, name, "X2 SUPERSTRIKE") == null) continue;
        const capability_path = try std.fmt.allocPrint(
            allocator,
            "/sys/class/input/{s}/device/capabilities/rel",
            .{entry.name},
        );
        const capability = std.Io.Dir.cwd().readFileAlloc(
            io,
            capability_path,
            allocator,
            .limited(256),
        ) catch continue;
        if (hasRelativeXY(capability))
            return std.fmt.allocPrint(allocator, "/dev/input/{s}", .{entry.name});
    }
    return error.MotionEventNotFound;
}

fn hasRelativeXY(capability: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, capability, " \t\r\n");
    var least_significant: ?[]const u8 = null;
    while (words.next()) |word| least_significant = word;
    const bits = std.fmt.parseInt(u64, least_significant orelse return false, 16) catch return false;
    return bits & 0x3 == 0x3;
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
        \\  px2 snapshot [--json]
        \\  px2 doctor [--json]
        \\  px2 get hits|dpi|rate|profiles [--json]
        \\  px2 set hits left|right|both [--actuation N] [--rapid N] [--haptics N]
        \\  px2 set dpi DPI [--profile N] [--dry-run]
        \\  px2 set rate HZ [--profile N] [--dry-run]
        \\  px2 profile list|inspect|show N|activate N
        \\  px2 profile initialize N --from-factory [--dry-run]
        \\  px2 profile export N FILE
        \\  px2 profile apply N FILE [--dry-run]
        \\  px2 rate measure
        \\  px2 watch [--idle-seconds 30] [--trace]
        \\  px2 watch status [--json]
        \\
        \\Global options:
        \\  --connection auto|direct|receiver
        \\  --device /dev/hidrawN
        \\  --timeout MILLISECONDS
        \\  --json
        \\  --dry-run
        \\  --backup-dir PATH
        \\  --state-dir PATH
        \\
    );
}

test "connection option parsing" {
    try std.testing.expectEqual(core.discovery.Filter.receiver, try parseConnection("receiver"));
    try std.testing.expectError(error.InvalidConnection, parseConnection("bluetooth"));
}

test "watch options preserve explicit connection and reject zero idle threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try parseArgs(allocator, &.{ "watch", "--state-dir", "/tmp/test-state", "--connection=receiver", "--idle-seconds", "10", "--trace" });
    try std.testing.expectEqual(@as(u32, 10), parsed.options.idle_seconds);
    try std.testing.expect(parsed.options.trace and parsed.options.connection_explicit);
    try std.testing.expectEqual(core.discovery.Filter.receiver, parsed.options.connection);
    try std.testing.expectEqualStrings("/tmp/test-state", parsed.options.state_dir.?);
    try std.testing.expectError(error.InvalidOption, parseArgs(allocator, &.{ "watch", "--idle-seconds", "0" }));
    try std.testing.expectError(error.MissingOptionValue, parseArgs(allocator, &.{ "watch", "--state-dir" }));
}

test "ROM and RAM sectors map to the same profile slot" {
    try std.testing.expectEqual(@as(u8, 1), try profileSlot(0x0101));
    try std.testing.expectEqual(@as(u8, 1), try profileSlot(0x0001));
    try std.testing.expectError(error.InvalidProfile, profileSlot(0x0100));
}

test "relative capability requires both X and Y axes" {
    try std.testing.expect(hasRelativeXY("1943\n"));
    try std.testing.expect(hasRelativeXY("00000000 00001943\n"));
    try std.testing.expect(!hasRelativeXY("1940\n"));
    try std.testing.expect(!hasRelativeXY("not-hex\n"));
}
