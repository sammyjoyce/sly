//! Source file that exposes the executable's API and test suite to users, Autodoc, and the build system.
//!
//! This module provides the core API for the sly command generator, allowing it to be used
//! as a library or from the CLI.

const std = @import("std");
const ctx = @import("context.zig");
const providers = @import("providers.zig");
const build_options = @import("build_options");

/// Version information (set by build system)
pub const version = build_options.version;

// Re-export core types for convenience
pub const Provider = providers.Provider;
pub const Config = providers.Config;

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

/// Build a system prompt with context and optional extensions.
/// The caller is responsible for freeing the returned string.
pub fn buildSystemPrompt(allocator: std.mem.Allocator, context: []const u8, extend: ?[]const u8) ![]u8 {
    const base =
        \\You are a shell command generator. Generate syntactically correct shell commands based on the user's natural language request.
        \\
        \\IMPORTANT RULES:
        \\1. Output ONLY the raw command - no explanations, no markdown, no backticks
        \\2. For arguments containing spaces or special characters, use single quotes
        \\3. Use double quotes only when variable expansion is needed
        \\4. Properly escape special characters within quotes
        \\
        \\Examples:
        \\- echo 'Hello World!'
        \\- echo "Current user: $USER"
        \\- grep 'pattern with spaces' file.txt
        \\- find . -name '*.txt'
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

    return buf.toOwnedSlice(allocator);
}

/// Load configuration from environment variables.
/// The caller is responsible for freeing the Config using freeConfig.
pub fn loadConfigFromEnv(allocator: std.mem.Allocator) !Config {
    const provider_env = try getEnvOr(allocator, "SLY_PROVIDER", "anthropic");
    defer allocator.free(provider_env);

    return Config{
        .provider = parseProvider(provider_env),
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
pub fn generate(allocator: std.mem.Allocator, query: []const u8, config: Config) ![]u8 {
    const context = try ctx.buildContext(allocator);
    defer allocator.free(context);

    const extend = getEnvOpt(allocator, "SLY_PROMPT_EXTEND");
    defer if (extend) |e| allocator.free(e);

    const prompt = try buildSystemPrompt(allocator, context, extend);
    defer allocator.free(prompt);

    return providers.query(allocator, config, query, prompt) catch |e| blk: {
        const msg = switch (e) {
            error.MissingApiKey => "API Error: Missing API key",
            error.BadResponse => "Error: Unable to parse response",
            error.Network, error.Unavailable => "Error: Failed to connect to provider",
            else => "Error: Unknown",
        };
        break :blk try allocator.dupe(u8, msg);
    };
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
    const prompt = try buildSystemPrompt(allocator, test_context, null);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "shell command generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Test context") != null);
}

test "buildSystemPrompt includes extension" {
    const allocator = std.testing.allocator;
    const test_context = "Test context";
    const test_extend = "Additional instructions";
    const prompt = try buildSystemPrompt(allocator, test_context, test_extend);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Additional instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Test context") != null);
}
