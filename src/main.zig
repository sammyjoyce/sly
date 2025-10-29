const std = @import("std");
const sly = @import("sly.zig");

fn installShellCommand(alloc: std.mem.Allocator, args_iter: *std.process.ArgIterator) !void {
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);

    // Check for shell argument
    var requested_shell: ?sly.ShellType = null;
    var auto_source = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "bash")) {
            requested_shell = .bash;
        } else if (std.mem.eql(u8, arg, "zsh")) {
            requested_shell = .zsh;
        } else if (std.mem.eql(u8, arg, "--auto") or std.mem.eql(u8, arg, "-a")) {
            auto_source = true;
        }
    }

    // Detect shell if not specified
    const shell = requested_shell orelse sly.detectShell(alloc);

    if (shell == .unknown) {
        try stdout_writer.interface.print(
            \\Unable to detect shell type. Please specify explicitly:
            \\  sly install-shell bash
            \\  sly install-shell zsh
            \\
        , .{});
        try stdout_writer.interface.flush();
        return error.UnknownShell;
    }

    try stdout_writer.interface.print("Installing {s} integration...\n", .{shell.toString()});
    try stdout_writer.interface.flush();

    sly.installShellIntegration(alloc, shell, auto_source) catch |err| {
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

    if (auto_source) {
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
            \\  sly install-shell --auto
            \\
        , .{ shell.rcFile(), plugin_path });
    }

    try stdout_writer.interface.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    // Collect all arguments into a query string
    var query_buf = std.ArrayList(u8){};
    defer query_buf.deinit(alloc);

    // Check for flags and commands first
    const first_arg = args_iter.next();
    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            var stdout_buf: [4096]u8 = undefined;
            const stdout_file = std.fs.File.stdout();
            var stdout_writer = stdout_file.writer(&stdout_buf);
            try stdout_writer.interface.print("sly {s}\n", .{sly.version});
            try stdout_writer.interface.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "install-shell")) {
            try installShellCommand(alloc, &args_iter);
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout_buf: [4096]u8 = undefined;
            const stdout_file = std.fs.File.stdout();
            var stdout_writer = stdout_file.writer(&stdout_buf);
            try stdout_writer.interface.print(
                \\sly {s} - Shell AI command generator
                \\
                \\Usage:
                \\  sly [OPTIONS] "natural language query"
                \\  sly install-shell [bash|zsh] [--auto]
                \\
                \\Options:
                \\  -h, --help     Show this help message
                \\  -v, --version  Show version information
                \\
                \\Commands:
                \\  install-shell [bash|zsh]  Install shell integration (auto-detects if not specified)
                \\    --auto, -a              Automatically add source line to shell rc file
                \\
                \\Examples:
                \\  sly "list all pdf files"
                \\  sly "show disk usage sorted by size"
                \\  sly install-shell         # Auto-detect and install
                \\  sly install-shell zsh --auto
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
            return;
        }

        // Not a flag, add to query
        try query_buf.appendSlice(alloc, arg);
    }

    // Collect remaining arguments
    while (args_iter.next()) |arg| {
        try query_buf.append(alloc, ' ');
        try query_buf.appendSlice(alloc, arg);
    }

    const saw_any = query_buf.items.len > 0;

    // Show usage if no arguments provided
    if (!saw_any) {
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const provider_name = std.process.getEnvVarOwned(alloc, "SLY_PROVIDER") catch "anthropic";
        defer if (!std.mem.eql(u8, provider_name, "anthropic")) alloc.free(provider_name);
        try stdout_writer.interface.print("Usage: sly \"your natural language command\"\nCurrent provider: {s}\nRun 'sly --help' for more information.\n", .{provider_name});
        try stdout_writer.interface.flush();
        return;
    }

    const query_text = try query_buf.toOwnedSlice(alloc);
    defer alloc.free(query_text);

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
}
