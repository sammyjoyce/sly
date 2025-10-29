const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate version info
    const version = b.option([]const u8, "version", "Override version string") orelse "0.1.0";
    const version_file = b.addOptions();
    version_file.addOption([]const u8, "version", version);
    version_file.addOption([]const u8, "build_mode", @tagName(optimize));

    // Get argzon dependency
    const argzon_dep = b.dependency("argzon", .{
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    root_mod.addImport("build_options", version_file.createModule());
    root_mod.addImport("argzon", argzon_dep.module("argzon"));

    const exe = b.addExecutable(.{
        .name = "sly",
        .root_module = root_mod,
    });
    exe.linkLibC();

    // Try pkg-config first (for nix develop), fall back to system search
    exe.linkSystemLibrary2("curl", .{ .use_pkg_config = .yes });

    b.installArtifact(exe);

    // Install shell integrations
    const install_shell_integrations = b.step("install-shell", "Install shell integration plugins");

    // Install zsh plugin
    const install_zsh = b.addInstallFile(
        b.path("src/sly.plugin.zsh"),
        "lib/sly.plugin.zsh",
    );
    install_shell_integrations.dependOn(&install_zsh.step);
    b.getInstallStep().dependOn(&install_zsh.step);

    // Install bash plugin
    const install_bash = b.addInstallFile(
        b.path("src/bash-sly.plugin.sh"),
        "lib/bash-sly.plugin.sh",
    );
    install_shell_integrations.dependOn(&install_bash.step);
    b.getInstallStep().dependOn(&install_bash.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run sly");
    run_step.dependOn(&run_cmd.step);

    // Add test step
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Add check step for ZLS build-on-save
    const exe_check = b.addExecutable(.{
        .name = "sly",
        .root_module = root_mod,
    });
    exe_check.linkLibC();
    exe_check.linkSystemLibrary2("curl", .{ .use_pkg_config = .yes });
    const check = b.step("check", "Check if sly compiles");
    check.dependOn(&exe_check.step);
}
