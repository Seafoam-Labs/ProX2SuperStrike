const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("superstrike", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "px2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "superstrike", .module = core }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run px2").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    const cli_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    const gui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/gui/model.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-gui", "Test GUI protocol and editing model (no display required)").dependOn(&b.addRunArtifact(gui_tests).step);

    if (b.option(bool, "gui", "Build the GTK4 configuration editor (default: true)") orelse true) {
        const bindings = b.lazyDependency("gobject", .{ .target = target, .optimize = optimize }) orelse return;
        const module = b.createModule(.{
            .root_source_file = b.path("src/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "cairo1" }) |name|
            module.addImport(name, bindings.module(name));
        module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
        module.addAnonymousImport("style", .{ .root_source_file = b.path("resources/gui/style.css") });
        const gui = b.addExecutable(.{ .name = "px2-gui", .root_module = module });
        b.installArtifact(gui);
        b.installFile("packaging/px2-gui.desktop", "share/applications/io.github.px2.Configurator.desktop");
        b.installFile("resources/gui/px2.svg", "share/icons/hicolor/scalable/apps/io.github.px2.Configurator.svg");
        b.installFile("docs/GUI.md", "share/doc/prox2-superstrike/GUI.md");
        const gui_run = b.addRunArtifact(gui);
        gui_run.step.dependOn(b.getInstallStep());
        if (b.args) |args| gui_run.addArgs(args);
        b.step("run-gui", "Run the GTK4 editor").dependOn(&gui_run.step);
        const smoke = b.addSystemCommand(&.{ "python3", "tests/gui/smoke.py" });
        smoke.addArtifactArg(gui);
        b.step("smoke-gui", "Exercise native GTK with a fake CLI (requires a display)").dependOn(&smoke.step);
    }
}
