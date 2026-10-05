const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information from the binary");

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe_mod.addOptions("build_options", options);

    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    const exe = b.addExecutable(.{ .name = "pim", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run pim").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" }, .check = true });
    b.step("fmt", "Check formatting").dependOn(&fmt.step);
}
