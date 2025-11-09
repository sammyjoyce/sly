//! Source file that exposes the executable's API and test suite to users, Autodoc, and the build system.
//!
//! This module provides the core API for the sly command generator, allowing it to be used
//! as a library or from the CLI.

const std = @import("std");
const ctx = @import("context.zig");
const providers = @import("providers.zig");
const build_options = @import("build_options");
const command_planner = @import("command_planner.zig");
const ghostty = @import("libghostty.zig");
pub const terminal_runtime = @import("terminal_runtime.zig");

/// Version information (set by build system)
pub const version = build_options.version;

// Re-export core types for convenience
pub const Provider = providers.Provider;
pub const Config = providers.Config;
pub const CommandPlan = command_planner.CommandPlan;
pub const PlanOutcome = command_planner.PlanOutcome;

// Shell integration scripts embedded at compile time
pub const zsh_plugin = @embedFile("sly.plugin.zsh");
pub const bash_plugin = @embedFile("bash-sly.plugin.sh");

/// Parse a provider name string into a Provider enum.
/// Returns .anthropic as the default for unknown provider names.
pub fn parseProvider(name: []const u8) Provider {
    if (std.mem.eql(u8, name, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, name, "gemini")) return .gemini;
    if (std.mem.eql(u8, name, "openai")) return .openai;
    if (std.mem.eql(u8, name, "ollama")) return .ollama;
    if (std.mem.eql(u8, name, "echo")) return .echo;
    return .anthropic;
}

/// Auto-detect provider based on available API keys.
/// Priority: anthropic -> openai -> gemini -> ollama (fallback).
/// Returns the provider to use.
pub fn autoDetectProvider(allocator: std.mem.Allocator) Provider {
    // Check if provider is explicitly set
    if (getEnvOpt(allocator, "SLY_PROVIDER")) |provider_env| {
        defer allocator.free(provider_env);
        return parseProvider(provider_env);
    }

    // Auto-detect based on available API keys
    // Priority: anthropic -> openai -> gemini -> ollama (fallback)
    if (getEnvOpt(allocator, "ANTHROPIC_API_KEY")) |key| {
        allocator.free(key);
        return .anthropic;
    }

    if (getEnvOpt(allocator, "OPENAI_API_KEY")) |key| {
        allocator.free(key);
        return .openai;
    }

    if (getEnvOpt(allocator, "GEMINI_API_KEY")) |key| {
        allocator.free(key);
        return .gemini;
    }

    // Default to ollama if no API keys found (local, no key needed)
    return .ollama;
}

/// Get an environment variable with a default fallback.
/// The caller is responsible for freeing the returned string.
pub fn getEnvOr(allocator: std.mem.Allocator, key: []const u8, default_value: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch try allocator.dupe(u8, default_value);
}

/// Get an environment variable, returning null if not set.
/// The caller is responsible for freeing the returned string if non-null.
pub fn getEnvOpt(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

/// Format a terminal snapshot for inclusion in AI prompts.
/// Returns a human-readable summary of the terminal state.
/// Caller is responsible for freeing the returned string.
pub fn formatSnapshotForPrompt(allocator: std.mem.Allocator, snapshot: *const terminal_runtime.Snapshot) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);

    // Add header
    try writer.print("Terminal State ({}x{}):\n", .{ snapshot.cols, snapshot.rows });
    try writer.print("Cursor Position: row {}, col {}\n", .{ snapshot.cursor_row, snapshot.cursor_col });

    // Add recent terminal output (last few non-empty lines)
    var line_count: usize = 0;
    const max_lines = 10;

    var i: isize = @as(isize, @intCast(snapshot.framebuffer.len)) - 1;
    while (i >= 0 and line_count < max_lines) : (i -= 1) {
        const row_idx: usize = @intCast(i);
        const row = snapshot.framebuffer[row_idx];

        // Skip empty rows
        var has_content = false;
        for (row) |cell| {
            if (cell.char != ' ' and cell.char != 0) {
                has_content = true;
                break;
            }
        }

        if (!has_content) continue;

        // Extract text from row
        var line_buf = std.ArrayList(u8){};
        defer line_buf.deinit(allocator);

        for (row) |cell| {
            if (cell.char != 0) {
                try line_buf.append(allocator, cell.char);
            }
        }

        // Trim trailing spaces
        var text = line_buf.items;
        while (text.len > 0 and text[text.len - 1] == ' ') {
            text = text[0 .. text.len - 1];
        }

        if (text.len > 0) {
            try writer.print("  | {s}\n", .{text});
            line_count += 1;
        }
    }

    if (line_count == 0) {
        try writer.writeAll("  | (empty)\n");
    }

    // Add OSC events (with privacy filtering)
    if (snapshot.osc_events.len > 0) {
        try writer.writeAll("\nRecent Shell Events:\n");

        for (snapshot.osc_events, 0..) |event, idx| {
            if (idx >= 5) break; // Only show last 5 events

            const event_name = switch (event.command_type) {
                ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE => "Window Title Change",
                ghostty.OSC_COMMAND_REPORT_PWD => "Directory Change",
                ghostty.OSC_COMMAND_PROMPT_START => "Prompt Start",
                ghostty.OSC_COMMAND_PROMPT_END => "Prompt End",
                else => "Other OSC Command",
            };

            try writer.print("  - {s}", .{event_name});

            // Only include safe payloads (avoid clipboard/sensitive data)
            if (event.payload) |payload| {
                if (event.command_type == ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE or
                    event.command_type == ghostty.OSC_COMMAND_REPORT_PWD)
                {
                    // Limit length to avoid huge prompts
                    const max_payload_len = 100;
                    const safe_payload = if (payload.len > max_payload_len)
                        payload[0..max_payload_len]
                    else
                        payload;
                    try writer.print(": {s}", .{safe_payload});
                    if (payload.len > max_payload_len) {
                        try writer.writeAll("...");
                    }
                }
            }

            try writer.writeAll("\n");
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Build a system prompt with context and optional extensions.
/// The caller is responsible for freeing the returned string.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    context: []const u8,
    extend: ?[]const u8,
    snapshot: ?*const terminal_runtime.Snapshot,
) ![]u8 {
    const base =
        \\You are a shell command generator. Generate a CommandPlan JSON schema for executing shell commands based on the user's natural language request.
        \\
        \\CRITICAL: Your response must be ONLY the JSON object. Do not include:
        \\- Explanations before or after the JSON
        \\- Markdown code fences (```json or ```)
        \\- Any text outside the JSON object
        \\- Newlines before the opening brace
        \\
        \\Start your response with { and end with }
        \\
        \\CommandPlan JSON Schema:
        \\{
        \\  "plan_id": "unique-id-string",
        \\  "command": "base-command",
        \\  "args": ["arg1", "arg2"],
        \\  "env": {"VAR": "value"},
        \\  "stdin": "optional stdin data or null",
        \\  "paste_policy": "auto|needs_confirm|never",
        \\  "confirm_mode": "auto|preview|reject",
        \\  "expectations": [{"pattern": "expected output pattern", "exit_code": 0}],
        \\  "failure_signals": [{"pattern": "error pattern", "severity": "warning|err|critical"}],
        \\  "created_at": 0
        \\}
        \\
        \\SCHEMA RULES:
        \\1. plan_id: Generate a unique identifier (e.g., "cmd-" + timestamp)
        \\2. command: The base command without arguments (e.g., "echo", "git", "find")
        \\3. args: Array of command arguments (use proper quoting for spaces/special chars)
        \\4. env: Object with environment variables (empty {} if none needed)
        \\5. stdin: String for piped input, or null if not needed
        \\6. paste_policy: "auto" for safe commands, "needs_confirm" for potentially dangerous ones
        \\7. confirm_mode: "auto" for safe execution, "preview" to show before running
        \\8. expectations: Optional array of expected outcomes for validation
        \\9. failure_signals: Optional array of error patterns to detect failures
        \\10. created_at: Unix timestamp (use current time in milliseconds)
        \\
        \\Examples:
        \\
        \\User: "say hello"
        \\{"plan_id":"cmd-1","command":"echo","args":["Hello World!"],"env":{},"stdin":null,"paste_policy":"auto","confirm_mode":"auto","expectations":[],"failure_signals":[],"created_at":1699564800000}
        \\
        \\User: "find all text files"
        \\{"plan_id":"cmd-2","command":"find","args":[".","-name","*.txt"],"env":{},"stdin":null,"paste_policy":"auto","confirm_mode":"auto","expectations":[],"failure_signals":[],"created_at":1699564800000}
        \\
        \\User: "delete all logs"
        \\{"plan_id":"cmd-3","command":"rm","args":["-rf","*.log"],"env":{},"stdin":null,"paste_policy":"needs_confirm","confirm_mode":"preview","expectations":[],"failure_signals":[{"pattern":"cannot remove","severity":"err"}],"created_at":1699564800000}
    ;

    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, base);
    if (extend) |e| {
        try buf.appendSlice(allocator, "\n\n");
        try buf.appendSlice(allocator, e);
    }
    try buf.appendSlice(allocator, "\n\nContext:\n");
    try buf.appendSlice(allocator, context);

    // Add terminal snapshot context if provided
    if (snapshot) |snap| {
        const snapshot_text = try formatSnapshotForPrompt(allocator, snap);
        defer allocator.free(snapshot_text);

        try buf.appendSlice(allocator, "\n\n");
        try buf.appendSlice(allocator, snapshot_text);
    }

    return buf.toOwnedSlice(allocator);
}

/// Load configuration from environment variables.
/// The caller is responsible for freeing the Config using freeConfig.
pub fn loadConfigFromEnv(allocator: std.mem.Allocator) !Config {
    return Config{
        .provider = autoDetectProvider(allocator),
        .anthropic_key = getEnvOpt(allocator, "ANTHROPIC_API_KEY"),
        .anthropic_model = try getEnvOr(allocator, "SLY_ANTHROPIC_MODEL", "claude-3-5-sonnet-20241022"),
        .gemini_key = getEnvOpt(allocator, "GEMINI_API_KEY"),
        .gemini_model = try getEnvOr(allocator, "SLY_GEMINI_MODEL", "gemini-2.0-flash-exp"),
        .openai_key = getEnvOpt(allocator, "OPENAI_API_KEY"),
        .openai_model = try getEnvOr(allocator, "SLY_OPENAI_MODEL", "gpt-4o"),
        .openai_url = try getEnvOr(allocator, "SLY_OPENAI_URL", "https://api.openai.com/v1/responses"),
        .ollama_model = try getEnvOr(allocator, "SLY_OLLAMA_MODEL", "llama3.2"),
        .ollama_url = try getEnvOr(allocator, "SLY_OLLAMA_URL", "http://localhost:11434"),
    };
}

/// Free all allocated memory in a Config struct.
pub fn freeConfig(allocator: std.mem.Allocator, config: Config) void {
    if (config.anthropic_key) |v| allocator.free(v);
    if (config.gemini_key) |v| allocator.free(v);
    if (config.openai_key) |v| allocator.free(v);
    allocator.free(config.anthropic_model);
    allocator.free(config.gemini_model);
    allocator.free(config.openai_model);
    allocator.free(config.openai_url);
    allocator.free(config.ollama_model);
    allocator.free(config.ollama_url);
}

/// Generate a shell command from a natural language query.
///
/// This is the main entry point for the sly API. It takes a query string and configuration,
/// builds the necessary context and prompts, and returns the generated command.
///
/// The caller is responsible for freeing the returned string.
/// Validate that the configuration has the necessary API key for the selected provider.
/// Returns an error with a helpful message if the key is missing or appears invalid.
pub fn validateConfig(config: Config) !void {
    switch (config.provider) {
        .anthropic => {
            const key = config.anthropic_key orelse {
                std.log.err("Anthropic provider selected but ANTHROPIC_API_KEY is not set.", .{});
                std.log.err("Get your API key from: https://console.anthropic.com/settings/keys", .{});
                std.log.err("Then set it: export ANTHROPIC_API_KEY='sk-ant-...'", .{});
                return error.MissingApiKey;
            };
            if (key.len < 10) {
                std.log.err("ANTHROPIC_API_KEY appears invalid (too short: {} chars)", .{key.len});
                std.log.err("Expected format: sk-ant-... (40+ characters)", .{});
                return error.InvalidApiKey;
            }
        },
        .openai => {
            const key = config.openai_key orelse {
                std.log.err("OpenAI provider selected but OPENAI_API_KEY is not set.", .{});
                std.log.err("Get your API key from: https://platform.openai.com/api-keys", .{});
                std.log.err("Then set it: export OPENAI_API_KEY='sk-...'", .{});
                return error.MissingApiKey;
            };
            if (key.len < 10) {
                std.log.err("OPENAI_API_KEY appears invalid (too short: {} chars)", .{key.len});
                std.log.err("Expected format: sk-... (40+ characters)", .{});
                return error.InvalidApiKey;
            }
        },
        .gemini => {
            const key = config.gemini_key orelse {
                std.log.err("Gemini provider selected but GEMINI_API_KEY is not set.", .{});
                std.log.err("Get your API key from: https://makersuite.google.com/app/apikey", .{});
                std.log.err("Then set it: export GEMINI_API_KEY='...'", .{});
                return error.MissingApiKey;
            };
            if (key.len < 10) {
                std.log.err("GEMINI_API_KEY appears invalid (too short: {} chars)", .{key.len});
                return error.InvalidApiKey;
            }
        },
        .ollama => {},
        .echo => {},
    }
}

/// Generate a shell command from a natural language query.
///
/// This is the main entry point for the sly API. It takes a query string and configuration,
/// builds the necessary context and prompts, and returns the generated command as a JSON string.
///
/// The caller is responsible for freeing the returned string.
pub fn generate(
    allocator: std.mem.Allocator,
    query: []const u8,
    config: Config,
    snapshot: ?*const terminal_runtime.Snapshot,
) ![]u8 {
    try validateConfig(config);

    const context = try ctx.buildContext(allocator);
    defer allocator.free(context);

    const extend = getEnvOpt(allocator, "SLY_PROMPT_EXTEND");
    defer if (extend) |e| allocator.free(e);

    const prompt = try buildSystemPrompt(allocator, context, extend, snapshot);
    defer allocator.free(prompt);

    return providers.query(allocator, config, query, prompt) catch |e| blk: {
        if (config.provider != .echo and (e == error.Network or e == error.Unavailable)) {
            var fallback_cfg = config;
            fallback_cfg.provider = .echo;

            break :blk providers.query(allocator, fallback_cfg, query, prompt) catch |fallback_err| fall: {
                const fallback_msg = switch (fallback_err) {
                    error.MissingApiKey => "API Error: Missing API key",
                    error.BadResponse => "Error: Unable to parse response",
                    error.Network, error.Unavailable => "Error: Failed to connect to provider",
                    else => "Error: Unknown",
                };
                break :fall try allocator.dupe(u8, fallback_msg);
            };
        }

        const msg = switch (e) {
            error.MissingApiKey => "API Error: Missing API key",
            error.BadResponse => "Error: Unable to parse response",
            error.Network, error.Unavailable => "Error: Failed to connect to provider",
            else => "Error: Unknown",
        };
        break :blk try allocator.dupe(u8, msg);
    };
}

/// Generate and validate a CommandPlan from a natural language query.
///
/// This function calls generate() to get CommandPlan JSON from the provider,
/// then parses and validates it against the CommandPlan schema. It retries
/// up to max_retries times on validation errors.
///
/// Returns a validated CommandPlan struct. The caller is responsible for
/// freeing the plan using CommandPlan.deinit().
pub fn generatePlan(
    allocator: std.mem.Allocator,
    query: []const u8,
    config: Config,
    max_retries: u8,
    snapshot: ?*const terminal_runtime.Snapshot,
) !CommandPlan {
    var attempt: u8 = 0;
    var last_error: []const u8 = "";

    while (attempt < max_retries) : (attempt += 1) {
        const json_str = try generate(allocator, query, config, snapshot);
        defer allocator.free(json_str);

        std.log.debug("Attempt {d}/{d}: Received JSON response ({d} bytes)", .{ attempt + 1, max_retries, json_str.len });

        const plan = CommandPlan.fromJson(allocator, json_str) catch |err| {
            last_error = switch (err) {
                error.OutOfMemory => "Out of memory",
                error.InvalidCharacter, error.UnexpectedToken => "Invalid JSON syntax",
                error.UnknownField => "Unknown field in JSON",
                error.MissingField => "Missing required field",
                else => "JSON parsing error",
            };
            std.log.warn("Schema validation failed (attempt {d}/{d}): {s}", .{ attempt + 1, max_retries, last_error });
            continue;
        };

        std.log.info("Successfully validated CommandPlan: plan_id={s}, command={s}", .{ plan.plan_id, plan.command });
        return plan;
    }

    std.log.err("Failed to generate valid CommandPlan after {d} attempts. Last error: {s}", .{ max_retries, last_error });
    return error.ValidationFailed;
}

/// Shell types supported for integration
pub const ShellType = enum {
    bash,
    zsh,
    unknown,

    pub fn fromString(s: []const u8) ShellType {
        const basename = std.fs.path.basename(s);
        if (std.mem.eql(u8, basename, "zsh")) return .zsh;
        if (std.mem.eql(u8, basename, "bash")) return .bash;
        return .unknown;
    }

    pub fn toString(self: ShellType) []const u8 {
        return switch (self) {
            .bash => "bash",
            .zsh => "zsh",
            .unknown => "unknown",
        };
    }

    pub fn rcFile(self: ShellType) []const u8 {
        return switch (self) {
            .bash => ".bashrc",
            .zsh => ".zshrc",
            .unknown => "",
        };
    }

    pub fn pluginContent(self: ShellType) []const u8 {
        return switch (self) {
            .bash => bash_plugin,
            .zsh => zsh_plugin,
            .unknown => "",
        };
    }
};

/// Detect the current shell from environment
pub fn detectShell(allocator: std.mem.Allocator) ShellType {
    const shell_path = getEnvOpt(allocator, "SHELL") orelse return .unknown;
    defer allocator.free(shell_path);

    return ShellType.fromString(shell_path);
}

/// Install shell integration for the specified shell type
pub fn installShellIntegration(allocator: std.mem.Allocator, shell: ShellType, auto_source: bool) !void {
    if (shell == .unknown) return error.UnsupportedShell;

    // Get home directory
    const home = getEnvOpt(allocator, "HOME") orelse return error.NoHomeDir;
    defer allocator.free(home);

    // Create ~/.config/sly directory
    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "sly" });
    defer allocator.free(config_dir);

    std.fs.cwd().makePath(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write plugin file
    const plugin_filename = switch (shell) {
        .bash => "sly.plugin.sh",
        .zsh => "sly.plugin.zsh",
        .unknown => unreachable,
    };

    const plugin_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, plugin_filename });
    defer allocator.free(plugin_path);

    const plugin_file = try std.fs.cwd().createFile(plugin_path, .{});
    defer plugin_file.close();

    try plugin_file.writeAll(shell.pluginContent());

    // Optionally add source line to rc file
    if (auto_source) {
        const rc_path = try std.fs.path.join(allocator, &[_][]const u8{ home, shell.rcFile() });
        defer allocator.free(rc_path);

        const source_line = try std.fmt.allocPrint(
            allocator,
            "\n# sly shell integration\nsource {s}\n",
            .{plugin_path},
        );
        defer allocator.free(source_line);

        // Check if already sourced
        const rc_content = std.fs.cwd().readFileAlloc(allocator, rc_path, 1024 * 1024) catch |err| blk: {
            if (err == error.FileNotFound) {
                break :blk try allocator.dupe(u8, "");
            }
            return err;
        };
        defer allocator.free(rc_content);

        if (std.mem.indexOf(u8, rc_content, plugin_path) == null) {
            // Open or create the rc file in read-write mode, then append
            const rc_file = std.fs.cwd().openFile(rc_path, .{ .mode = .read_write }) catch |err| blk: {
                if (err == error.FileNotFound) {
                    // Create the file if it doesn't exist
                    break :blk try std.fs.cwd().createFile(rc_path, .{ .read = true });
                }
                return err;
            };
            defer rc_file.close();

            try rc_file.seekFromEnd(0);
            try rc_file.writeAll(source_line);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "parseProvider returns correct enum values" {
    try std.testing.expectEqual(Provider.anthropic, parseProvider("anthropic"));
    try std.testing.expectEqual(Provider.gemini, parseProvider("gemini"));
    try std.testing.expectEqual(Provider.openai, parseProvider("openai"));
    try std.testing.expectEqual(Provider.ollama, parseProvider("ollama"));
    try std.testing.expectEqual(Provider.echo, parseProvider("echo"));
}

test "parseProvider defaults to anthropic for unknown providers" {
    try std.testing.expectEqual(Provider.anthropic, parseProvider("unknown"));
    try std.testing.expectEqual(Provider.anthropic, parseProvider(""));
    try std.testing.expectEqual(Provider.anthropic, parseProvider("foo"));
}

test "buildSystemPrompt includes context" {
    const allocator = std.testing.allocator;
    const test_context = "Test context";
    const prompt = try buildSystemPrompt(allocator, test_context, null, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "CommandPlan JSON") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Test context") != null);
}

test "buildSystemPrompt includes extension" {
    const allocator = std.testing.allocator;
    const test_context = "Test context";
    const test_extend = "Additional instructions";
    const prompt = try buildSystemPrompt(allocator, test_context, test_extend, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Additional instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Test context") != null);
}

test "formatSnapshotForPrompt includes terminal state" {
    const allocator = std.testing.allocator;

    var runtime = try terminal_runtime.TerminalRuntime.init(allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer runtime.shutdown();

    try runtime.feedBytes("$ ls -la\n");
    try runtime.feedBytes("total 42\n");
    try runtime.feedBytes("drwxr-xr-x  5 user group 4096 Nov  9 10:00 .\n");

    var snapshot = try runtime.snapshot(.{});
    defer snapshot.deinit(allocator);

    const formatted = try formatSnapshotForPrompt(allocator, &snapshot);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Terminal State") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Cursor Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "ls -la") != null);
}
