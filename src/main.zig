const std = @import("std");
const sly = @import("sly.zig");
const cli = @import("cli.zig");

fn installShellCommand(alloc: std.mem.Allocator, install_args: cli.ShellInstallArgs) !void {
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);

    // Parse shell type from argument
    var requested_shell: ?sly.ShellType = null;
    if (install_args.shell) |shell_str| {
        if (std.mem.eql(u8, shell_str, "bash")) {
            requested_shell = .bash;
        } else if (std.mem.eql(u8, shell_str, "zsh")) {
            requested_shell = .zsh;
        }
    }

    // Detect shell if not specified
    const shell = requested_shell orelse sly.detectShell(alloc);

    if (shell == .unknown) {
        try stdout_writer.interface.print(
            \\Unable to detect shell type. Please specify explicitly:
            \\  sly shell install bash
            \\  sly shell install zsh
            \\
        , .{});
        try stdout_writer.interface.flush();
        return error.UnknownShell;
    }

    try stdout_writer.interface.print("Installing {s} integration...\n", .{shell.toString()});
    try stdout_writer.interface.flush();

    sly.installShellIntegration(alloc, shell, install_args.auto) catch |err| {
        try stdout_writer.interface.print("Error: Failed to install shell integration: {}\n", .{err});
        try stdout_writer.interface.flush();
        return err;
    };

    const home = sly.getEnvOpt(alloc, "HOME") orelse return error.NoHomeDir;
    defer alloc.free(home);

    const config_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "sly" });
    defer alloc.free(config_dir);

    const plugin_filename = switch (shell) {
        .bash => "sly.plugin.sh",
        .zsh => "sly.plugin.zsh",
        .unknown => unreachable,
    };

    const plugin_path = try std.fs.path.join(alloc, &[_][]const u8{ config_dir, plugin_filename });
    defer alloc.free(plugin_path);

    try stdout_writer.interface.print(
        \\✓ Shell integration installed successfully!
        \\
        \\Plugin file: {s}
        \\
    , .{plugin_path});

    if (install_args.auto) {
        const rc_file = try std.fs.path.join(alloc, &[_][]const u8{ home, shell.rcFile() });
        defer alloc.free(rc_file);

        try stdout_writer.interface.print(
            \\✓ Added source line to {s}
            \\
            \\Restart your shell or run: source {s}
            \\
        , .{ rc_file, rc_file });
    } else {
        try stdout_writer.interface.print(
            \\To enable, add this to your ~/{s}:
            \\  source {s}
            \\
            \\Or run with --auto to automatically update your rc file:
            \\  sly shell install --auto
            \\
        , .{ shell.rcFile(), plugin_path });
    }

    try stdout_writer.interface.flush();
}

fn showHelp() !void {
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    try stdout_writer.interface.print(
        \\sly {s} - Shell AI command generator
        \\
        \\Usage:
        \\  sly [OPTIONS] "natural language query"
        \\  sly shell install [--shell <bash|zsh>] [--auto]
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -v, --version  Show version information
        \\
        \\Commands:
        \\  shell install              Install shell integration
        \\    --shell <bash|zsh>       Specify shell (auto-detects if omitted)
        \\    --auto, -a               Automatically add source line to shell rc file
        \\
        \\Examples:
        \\  sly "list all pdf files"
        \\  sly "show disk usage sorted by size"
        \\  sly shell install                    # Auto-detect and install
        \\  sly shell install --shell zsh --auto # Install for zsh and update ~/.zshrc
        \\
        \\Environment Variables:
        \\  SLY_PROVIDER            AI provider (anthropic, gemini, openai, ollama, echo)
        \\  ANTHROPIC_API_KEY       Anthropic API key
        \\  GEMINI_API_KEY          Google Gemini API key
        \\  OPENAI_API_KEY          OpenAI API key
        \\  SLY_PROMPT_EXTEND       Additional system prompt instructions
        \\
        \\For full documentation, see README.md
        \\
    , .{sly.version});
    try stdout_writer.interface.flush();
}

fn showVersion() !void {
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    try stdout_writer.interface.print("sly {s}\n", .{sly.version});
    try stdout_writer.interface.flush();
}

fn showUsage(alloc: std.mem.Allocator) !void {
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const provider_name = std.process.getEnvVarOwned(alloc, "SLY_PROVIDER") catch "anthropic";
    defer if (!std.mem.eql(u8, provider_name, "anthropic")) alloc.free(provider_name);
    try stdout_writer.interface.print("Usage: sly \"your natural language command\"\nCurrent provider: {s}\nRun 'sly --help' for more information.\n", .{provider_name});
    try stdout_writer.interface.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse command-line arguments using argzon
    var parse_result = try cli.parseArgs(alloc);
    defer parse_result.deinit();

    switch (parse_result.command) {
        .version => try showVersion(),
        .help => try showHelp(),
        .shell_install => |install_args| try installShellCommand(alloc, install_args),
        .query => |query_text| {
            // Load configuration from environment
            const cfg = try sly.loadConfigFromEnv(alloc);
            defer sly.freeConfig(alloc, cfg);

            // Generate the command
            const out_cmd = try sly.generate(alloc, query_text, cfg);
            defer alloc.free(out_cmd);

            // Output the result
            var stdout_buf: [4096]u8 = undefined;
            const stdout_file = std.fs.File.stdout();
            var stdout_writer = stdout_file.writer(&stdout_buf);
            try stdout_writer.interface.print("{s}", .{out_cmd});
            try stdout_writer.interface.flush();
        },
    }
}
