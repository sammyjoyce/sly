const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate version info
    const version = b.option([]const u8, "version", "Override version string") orelse "0.1.0";
    const version_file = b.addOptions();
    version_file.addOption([]const u8, "version", version);
    version_file.addOption([]const u8, "build_mode", @tagName(optimize));

    const root_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    root_mod.addImport("build_options", version_file.createModule());

    const exe = b.addExecutable(.{
        .name = "sly",
        .root_module = root_mod,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("curl");
    b.installArtifact(exe);

    // Install shell integrations
    const install_shell_integrations = b.step("install-shell", "Install shell integration plugins");

    // Install zsh plugin
    const install_zsh = b.addInstallFile(
        b.path("lib/sly.plugin.zsh"),
        "lib/sly.plugin.zsh",
    );
    install_shell_integrations.dependOn(&install_zsh.step);
    b.getInstallStep().dependOn(&install_zsh.step);

    // Install bash plugin
    const install_bash = b.addInstallFile(
        b.path("lib/bash-sly.plugin.sh"),
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
}
