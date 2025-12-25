const std = @import("std");
const sly = @import("sly.zig");
const cli = @import("cli.zig");
const terminal = @import("terminal_runtime.zig");

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
        } else if (std.mem.eql(u8, shell_str, "fish")) {
            requested_shell = .fish;
        }
    }

    // Detect shell if not specified
    const shell = requested_shell orelse sly.detectShell(alloc);

    if (shell == .unknown) {
        try stdout_writer.interface.print(
            \\Unable to detect shell type. Please specify explicitly:
            \\  sly shell install bash
            \\  sly shell install zsh
            \\  sly shell install fish
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
        .fish => "sly.plugin.fish",
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
        \\  sly shell install [--shell <bash|zsh|fish>] [--auto]
        \\  sly feedbytes [--input "text"] [--snapshot] [--raw]
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -v, --version  Show version information
        \\
        \\Commands:
        \\  shell install              Install shell integration
        \\    --shell <bash|zsh|fish>  Specify shell (auto-detects if omitted)
        \\    --auto, -a               Automatically add source line to shell rc file
        \\
        \\  feedbytes                  Process VT sequences (for testing terminal runtime)
        \\    --input <text>           VT sequence input (reads from stdin if omitted)
        \\    --snapshot, -s           Show snapshot hash and metadata
        \\    --raw, -r                Show raw framebuffer cells with styling
        \\
        \\Examples:
        \\  sly "list all pdf files"
        \\  sly "show disk usage sorted by size"
        \\  sly shell install                    # Auto-detect and install
        \\  sly shell install --shell zsh --auto # Install for zsh and update ~/.zshrc
        \\  sly shell install --shell fish       # Install for Fish shell
        \\  sly feedbytes --input "Hello\x1b[1;31mWorld\x1b[0m" --snapshot
        \\  echo -e "\x1b[1mBold text\x1b[0m" | sly feedbytes --raw
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

fn feedbytesCommand(alloc: std.mem.Allocator, fb_args: cli.FeedbytesArgs) !void {
    var stdout_buf: [8192]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);

    // Get input: either from --input flag or stdin
    const input_bytes = blk: {
        if (fb_args.input) |input_str| {
            // Unescape common escape sequences in input string
            var unescaped = std.ArrayList(u8){};
            defer unescaped.deinit(alloc);

            var i: usize = 0;
            while (i < input_str.len) {
                if (input_str[i] == '\\' and i + 1 < input_str.len) {
                    switch (input_str[i + 1]) {
                        'x' => {
                            // Hex escape: \xNN
                            if (i + 3 < input_str.len) {
                                const hex = input_str[i + 2 .. i + 4];
                                const byte = std.fmt.parseInt(u8, hex, 16) catch {
                                    try unescaped.append(alloc, input_str[i]);
                                    i += 1;
                                    continue;
                                };
                                try unescaped.append(alloc, byte);
                                i += 4;
                                continue;
                            }
                        },
                        'n' => {
                            try unescaped.append(alloc, '\n');
                            i += 2;
                            continue;
                        },
                        'r' => {
                            try unescaped.append(alloc, '\r');
                            i += 2;
                            continue;
                        },
                        't' => {
                            try unescaped.append(alloc, '\t');
                            i += 2;
                            continue;
                        },
                        'e' => {
                            try unescaped.append(alloc, 0x1b); // ESC
                            i += 2;
                            continue;
                        },
                        '\\' => {
                            try unescaped.append(alloc, '\\');
                            i += 2;
                            continue;
                        },
                        else => {},
                    }
                }
                try unescaped.append(alloc, input_str[i]);
                i += 1;
            }

            break :blk try unescaped.toOwnedSlice(alloc);
        } else {
            // Read from stdin
            const stdin_file = std.fs.File.stdin();
            const input = try stdin_file.readToEndAlloc(alloc, 1024 * 1024); // Max 1MB
            break :blk input;
        }
    };
    defer alloc.free(input_bytes);

    // Initialize terminal runtime
    const init_params = terminal.InitParams{
        .cols = 80,
        .rows = 24,
        .policy_config = .{}, // Use default policy
    };

    var runtime = try terminal.TerminalRuntime.init(alloc, init_params);
    defer runtime.shutdown();

    // Feed bytes to terminal
    try runtime.feedBytes(input_bytes);

    // Create snapshot
    var snap = try runtime.snapshot(.{});
    defer snap.deinit(alloc);

    // Display results based on flags
    if (fb_args.snapshot) {
        try stdout_writer.interface.print(
            \\Terminal Snapshot
            \\  Hash: 0x{x:0>16}
            \\  Size: {d}x{d}
            \\  Cursor: ({d}, {d})
            \\  Timestamp: {d}
            \\  OSC Events: {d}
            \\
            \\
        , .{
            snap.hash,
            snap.cols,
            snap.rows,
            snap.cursor_col,
            snap.cursor_row,
            snap.timestamp,
            snap.osc_events.len,
        });
    }

    if (fb_args.raw) {
        try stdout_writer.interface.print("Framebuffer ({d}x{d}):\n", .{ snap.cols, snap.rows });
        for (snap.framebuffer, 0..) |row, row_idx| {
            try stdout_writer.interface.print("Row {d:2}: ", .{row_idx});
            for (row) |cell| {
                if (cell.char == 0 or cell.char == ' ') {
                    try stdout_writer.interface.print(" ", .{});
                } else {
                    try stdout_writer.interface.print("{c}", .{cell.char});
                }
            }

            // Show styling info for non-empty cells
            var has_style = false;
            for (row) |cell| {
                if (cell.bold or cell.italic or cell.underline != 0 or
                    cell.fg_color != .none or cell.bg_color != .none)
                {
                    has_style = true;
                    break;
                }
            }

            if (has_style) {
                try stdout_writer.interface.print(" [", .{});
                for (row, 0..) |cell, col_idx| {
                    if (cell.char != 0 and cell.char != ' ') {
                        var styles = std.ArrayList(u8){};
                        defer styles.deinit(alloc);

                        if (cell.bold) try styles.appendSlice(alloc, "B");
                        if (cell.italic) try styles.appendSlice(alloc, "I");
                        if (cell.underline != 0) try styles.appendSlice(alloc, "U");
                        switch (cell.fg_color) {
                            .none => {},
                            .indexed => |fg| {
                                var buf: [16]u8 = undefined;
                                const fg_str = try std.fmt.bufPrint(&buf, "fg{d}", .{fg});
                                try styles.appendSlice(alloc, fg_str);
                            },
                            .rgb => |c| {
                                var buf: [24]u8 = undefined;
                                const fg_str = try std.fmt.bufPrint(&buf, "fg#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
                                try styles.appendSlice(alloc, fg_str);
                            },
                        }
                        switch (cell.bg_color) {
                            .none => {},
                            .indexed => |bg| {
                                var buf: [16]u8 = undefined;
                                const bg_str = try std.fmt.bufPrint(&buf, "bg{d}", .{bg});
                                try styles.appendSlice(alloc, bg_str);
                            },
                            .rgb => |c| {
                                var buf: [24]u8 = undefined;
                                const bg_str = try std.fmt.bufPrint(&buf, "bg#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
                                try styles.appendSlice(alloc, bg_str);
                            },
                        }

                        if (styles.items.len > 0) {
                            try stdout_writer.interface.print("{d}:{s} ", .{ col_idx, styles.items });
                        }
                    }
                }
                try stdout_writer.interface.print("]", .{});
            }

            try stdout_writer.interface.print("\n", .{});
        }
        try stdout_writer.interface.print("\n", .{});
    }

    // Always show rendered output (default)
    if (!fb_args.raw) {
        try stdout_writer.interface.print("Rendered Output:\n", .{});
        for (snap.framebuffer) |row| {
            for (row) |cell| {
                if (cell.char == 0 or cell.char == ' ') {
                    try stdout_writer.interface.print(" ", .{});
                } else {
                    try stdout_writer.interface.print("{c}", .{cell.char});
                }
            }
            try stdout_writer.interface.print("\n", .{});
        }
    }

    // Show OSC events if any
    if (snap.osc_events.len > 0) {
        try stdout_writer.interface.print("\nOSC Events ({d}):\n", .{snap.osc_events.len});
        for (snap.osc_events, 0..) |event, idx| {
            const verdict_str = if (!event.allowed) "rejected" else if (event.needs_confirmation) "confirm" else "allowed";
            const rationale_str = event.rationale orelse "(no rationale)";
            try stdout_writer.interface.print("  {d}. Type: {d}, Verdict: {s}, Rationale: {s}\n", .{
                idx + 1,
                event.command_type,
                verdict_str,
                rationale_str,
            });
        }
    }

    try stdout_writer.interface.flush();
}

fn planCommand(alloc: std.mem.Allocator, plan_args: cli.PlanArgs) !void {
    var stdout_buf: [16384]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);

    // Load configuration from environment
    const cfg = try sly.loadConfigFromEnv(alloc);
    defer sly.freeConfig(alloc, cfg);

    // Create snapshot from context if provided
    var snapshot_opt: ?sly.terminal_runtime.Snapshot = null;
    var runtime_opt: ?sly.terminal_runtime.TerminalRuntime = null;
    defer {
        if (snapshot_opt) |*snap| snap.deinit(alloc);
        if (runtime_opt) |*rt| rt.shutdown();
    }

    if (plan_args.context) |context| {
        // Create a temporary terminal runtime to parse the context
        const init_params = sly.terminal_runtime.InitParams{
            .cols = 80,
            .rows = 24,
        };
        var runtime = try sly.terminal_runtime.TerminalRuntime.init(alloc, init_params);

        // Feed the context bytes to build terminal state
        try runtime.feedBytes(context);

        // Capture snapshot with default options
        const snapshot_opts = sly.terminal_runtime.SnapshotOptions{};
        snapshot_opt = try runtime.snapshot(snapshot_opts);
        runtime_opt = runtime;
    }

    // Generate and validate the CommandPlan with retries
    var plan = try sly.generatePlan(alloc, plan_args.query, cfg, 3, if (snapshot_opt) |*snap| snap else null);
    defer plan.deinit(alloc);

    // Convert CommandPlan back to JSON for output
    const json_str = try plan.toJson(alloc);
    defer alloc.free(json_str);

    // Output the JSON
    try stdout_writer.interface.print("{s}\n", .{json_str});
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
        .feedbytes => |fb_args| try feedbytesCommand(alloc, fb_args),
        .plan => |plan_args| try planCommand(alloc, plan_args),
        .query => |query_text| {
            // Load configuration from environment
            const cfg = try sly.loadConfigFromEnv(alloc);
            defer sly.freeConfig(alloc, cfg);

            // Generate the command
            // TODO: Pass terminal snapshot when running in interactive mode
            const out_cmd = try sly.generate(alloc, query_text, cfg, null);
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
