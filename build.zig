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

    // Build libghostty-vt as a build step
    const build_libghostty = b.addSystemCommand(&.{
        "zig",
        "build",
        "lib-vt",
        "-Doptimize=ReleaseSafe",
    });
    build_libghostty.setCwd(b.path("vendor/ghostty"));

    // Add a custom build step to make it easy to build libghostty
    const libghostty_step = b.step("lib-ghostty", "Build libghostty-vt library");
    libghostty_step.dependOn(&build_libghostty.step);

    const exe = b.addExecutable(.{
        .name = "sly",
        .root_module = root_mod,
    });
    exe.linkLibC();

    // Add libghostty-vt C headers and library
    exe.addIncludePath(b.path("vendor/ghostty/include"));
    exe.addLibraryPath(b.path("vendor/ghostty/zig-out/lib"));
    exe.linkSystemLibrary("ghostty-vt");

    // Ensure libghostty-vt is built before sly
    exe.step.dependOn(&build_libghostty.step);

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

    // Test ghostty integration
    const libghostty_mod = b.createModule(.{
        .root_source_file = b.path("src/libghostty.zig"),
        .target = target,
        .optimize = optimize,
    });
    libghostty_mod.addIncludePath(b.path("vendor/ghostty/include"));
    libghostty_mod.link_libc = true;

    const policy_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/policy_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    policy_engine_mod.addImport("libghostty", libghostty_mod);

    const terminal_runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_runtime_mod.addImport("libghostty", libghostty_mod);
    terminal_runtime_mod.addImport("policy_engine", policy_engine_mod);

    const pty_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/pty_manager.zig"),
        .target = target,
        .optimize = optimize,
    });
    pty_manager_mod.addImport("terminal_runtime", terminal_runtime_mod);
    pty_manager_mod.link_libc = true;

    const command_planner_mod = b.createModule(.{
        .root_source_file = b.path("src/command_planner.zig"),
        .target = target,
        .optimize = optimize,
    });
    command_planner_mod.addImport("terminal_runtime", terminal_runtime_mod);
    command_planner_mod.addImport("policy_engine", policy_engine_mod);

    const test_ghostty_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/test_ghostty.zig"),
    });
    test_ghostty_mod.addImport("libghostty", libghostty_mod);
    test_ghostty_mod.addImport("terminal_runtime", terminal_runtime_mod);

    const test_ghostty_exe = b.addExecutable(.{
        .name = "test_ghostty",
        .root_module = test_ghostty_mod,
    });
    test_ghostty_exe.linkLibC();
    test_ghostty_exe.addIncludePath(b.path("vendor/ghostty/include"));
    test_ghostty_exe.addLibraryPath(b.path("vendor/ghostty/zig-out/lib"));
    test_ghostty_exe.linkSystemLibrary("ghostty-vt");
    test_ghostty_exe.step.dependOn(&build_libghostty.step);

    const test_ghostty_run = b.addRunArtifact(test_ghostty_exe);
    const test_ghostty_step = b.step("test-ghostty", "Test libghostty integration");
    test_ghostty_step.dependOn(&test_ghostty_run.step);

    // Add test step
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Add policy engine tests
    const policy_tests = b.addTest(.{
        .root_module = policy_engine_mod,
    });
    policy_tests.linkLibC();
    policy_tests.addIncludePath(b.path("vendor/ghostty/include"));
    const run_policy_tests = b.addRunArtifact(policy_tests);
    test_step.dependOn(&run_policy_tests.step);

    // Add terminal runtime tests
    const runtime_tests = b.addTest(.{
        .root_module = terminal_runtime_mod,
    });
    runtime_tests.linkLibC();
    runtime_tests.addIncludePath(b.path("vendor/ghostty/include"));
    runtime_tests.addLibraryPath(b.path("vendor/ghostty/zig-out/lib"));
    runtime_tests.linkSystemLibrary("ghostty-vt");
    runtime_tests.step.dependOn(&build_libghostty.step);

    const run_runtime_tests = b.addRunArtifact(runtime_tests);
    test_step.dependOn(&run_runtime_tests.step);

    // Add command planner tests
    const planner_tests = b.addTest(.{
        .root_module = command_planner_mod,
    });
    planner_tests.linkLibC();
    planner_tests.addIncludePath(b.path("vendor/ghostty/include"));
    planner_tests.addLibraryPath(b.path("vendor/ghostty/zig-out/lib"));
    planner_tests.linkSystemLibrary("ghostty-vt");
    planner_tests.step.dependOn(&build_libghostty.step);

    const run_planner_tests = b.addRunArtifact(planner_tests);
    test_step.dependOn(&run_planner_tests.step);

    // Add PTY manager tests
    const pty_tests = b.addTest(.{
        .root_module = pty_manager_mod,
    });
    pty_tests.linkLibC();
    pty_tests.addIncludePath(b.path("vendor/ghostty/include"));
    pty_tests.addLibraryPath(b.path("vendor/ghostty/zig-out/lib"));
    pty_tests.linkSystemLibrary("ghostty-vt");
    pty_tests.step.dependOn(&build_libghostty.step);

    const run_pty_tests = b.addRunArtifact(pty_tests);
    test_step.dependOn(&run_pty_tests.step);

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
