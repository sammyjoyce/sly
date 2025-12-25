//! Sly Core Module - Natural Language Shell Command Generation
//!
//! This module provides the central orchestration layer for sly, a tool that converts
//! natural language queries into executable shell commands using AI providers.
//!
//! ## Architecture Overview
//!
//! Sly follows a pipeline architecture:
//! 1. **Context Gathering**: Collect shell environment, git state, project info
//! 2. **Prompt Construction**: Build system prompts with CommandPlan schema
//! 3. **AI Query**: Send to provider (Anthropic, OpenAI, Gemini, Ollama)
//! 4. **Plan Validation**: Parse and validate JSON response against CommandPlan schema
//! 5. **Shell Integration**: Inject validated command into shell buffer
//!
//! ## Shell Integration Flow
//!
//! ```text
//! User types "# find large files" → Plugin captures query
//!                                  → sly plan --query "find large files"
//!                                  → AI generates CommandPlan JSON
//!                                  → Plugin parses JSON, replaces buffer
//!                                  → User sees: find . -size +100M
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//!
//! // Load configuration from environment
//! const config = try sly.loadConfigFromEnv(allocator);
//! defer sly.freeConfig(allocator, config);
//!
//! // Generate a command plan
//! const plan = try sly.generatePlan(allocator, "list all files", config, 3, null);
//! defer plan.deinit();
//!
//! std.debug.print("Command: {s}\n", .{plan.command});
//! ```
//!
//! ## Providers
//!
//! Supports multiple AI backends with automatic fallback:
//! - **Anthropic**: Claude models (default, requires ANTHROPIC_API_KEY)
//! - **OpenAI**: GPT models (requires OPENAI_API_KEY)
//! - **Gemini**: Google's models (requires GEMINI_API_KEY)
//! - **Ollama**: Local models (no API key, http://localhost:11434)
//! - **Echo**: Debug provider that echoes input (for testing)
//!
//! ## Memory Management
//!
//! All functions that allocate memory document ownership:
//! - Functions returning `[]u8` or `[]const u8` transfer ownership to caller
//! - Config structs must be freed with `freeConfig()`
//! - CommandPlan must be freed with `plan.deinit()`

const std = @import("std");
const ctx = @import("context.zig");
const providers = @import("providers.zig");
const build_options = @import("build_options");
const command_planner = @import("command_planner.zig");
const ghostty = @import("libghostty.zig");
pub const terminal_runtime = @import("terminal_runtime.zig");

/// Semantic version of the sly binary, set at compile time by the build system.
/// Format: "MAJOR.MINOR.PATCH" or "MAJOR.MINOR.PATCH-dev" for development builds.
pub const version = build_options.version;

// Re-export core types for convenience
/// AI provider backend selection. See `providers.zig` for implementation details.
pub const Provider = providers.Provider;

/// Configuration for AI provider connections (API keys, model names, URLs).
pub const Config = providers.Config;

/// Structured command plan returned by AI, ready for shell execution.
/// Contains command, arguments, environment, safety policies, and validation metadata.
pub const CommandPlan = command_planner.CommandPlan;

/// Result of command plan execution (success, failure, needs confirmation).
pub const PlanOutcome = command_planner.PlanOutcome;

// Shell integration scripts embedded at compile time
/// Zsh plugin script for `# query` shell integration.
/// Installs a preexec hook that intercepts lines starting with `#`.
pub const zsh_plugin = @embedFile("sly.plugin.zsh");

/// Bash plugin script for `# query` shell integration.
/// Uses readline bindings to intercept comment-style queries.
pub const bash_plugin = @embedFile("bash-sly.plugin.sh");

/// Fish plugin script for `# query` shell integration.
/// Uses fish's event system for command interception.
pub const fish_plugin = @embedFile("sly.plugin.fish");

/// Parse a provider name string into a Provider enum.
///
/// Converts human-readable provider names (from CLI args or environment)
/// into the Provider enum used internally.
///
/// Parameters:
/// - `name`: Provider name string ("anthropic", "gemini", "openai", "ollama", "echo")
///
/// Returns: Corresponding Provider enum value, or `.anthropic` for unknown names.
///
/// Example:
/// ```zig
/// const provider = parseProvider("openai"); // Returns .openai
/// const default = parseProvider("unknown"); // Returns .anthropic
/// ```
pub fn parseProvider(name: []const u8) Provider {
    if (std.mem.eql(u8, name, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, name, "gemini")) return .gemini;
    if (std.mem.eql(u8, name, "openai")) return .openai;
    if (std.mem.eql(u8, name, "ollama")) return .ollama;
    if (std.mem.eql(u8, name, "echo")) return .echo;
    return .anthropic;
}

/// Auto-detect the best available AI provider based on environment.
///
/// Checks for explicit provider selection via SLY_PROVIDER, then falls back
/// to detecting available API keys in priority order. This allows sly to
/// work out-of-the-box with whatever credentials the user has configured.
///
/// Detection priority:
/// 1. SLY_PROVIDER environment variable (explicit override)
/// 2. ANTHROPIC_API_KEY present → .anthropic
/// 3. OPENAI_API_KEY present → .openai
/// 4. GEMINI_API_KEY present → .gemini
/// 5. None found → .ollama (local, no key required)
///
/// Parameters:
/// - `allocator`: Allocator for temporary string operations
///
/// Returns: Best available Provider enum value.
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

/// Get an environment variable with a default fallback value.
///
/// Attempts to read the specified environment variable. If the variable
/// is not set or an error occurs, returns a copy of the default value.
///
/// Parameters:
/// - `allocator`: Allocator for the returned string
/// - `key`: Environment variable name
/// - `default_value`: Value to return if variable is not set
///
/// Returns: Owned copy of the variable value or default. Caller must free.
///
/// Errors:
/// - `error.OutOfMemory`: Allocation failure
pub fn getEnvOr(allocator: std.mem.Allocator, key: []const u8, default_value: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch try allocator.dupe(u8, default_value);
}

/// Get an optional environment variable.
///
/// Attempts to read the specified environment variable, returning null
/// if not set. Use this instead of getEnvOr when absence is meaningful.
///
/// Parameters:
/// - `allocator`: Allocator for the returned string
/// - `key`: Environment variable name
///
/// Returns: Owned copy of the variable value, or null if not set. Caller must free non-null result.
pub fn getEnvOpt(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

/// Format a terminal snapshot for inclusion in AI prompts.
///
/// Converts the terminal state (visible content, cursor position, recent OSC events)
/// into a human-readable summary suitable for providing context to the AI.
/// This allows sly to understand what the user is currently looking at.
///
/// The output includes:
/// - Terminal dimensions and cursor position
/// - Last N non-empty lines of visible content (max 10)
/// - Recent shell events (title changes, directory changes, prompt markers)
///
/// Privacy considerations:
/// - Only includes safe OSC payloads (titles, PWD)
/// - Excludes clipboard content and other sensitive data
/// - Truncates long payloads to 100 characters
///
/// Parameters:
/// - `allocator`: Allocator for the returned string
/// - `snapshot`: Terminal state snapshot from TerminalRuntime
///
/// Returns: Owned formatted string. Caller must free.
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

/// Build a complete system prompt for the AI provider.
///
/// Constructs the system prompt that instructs the AI how to generate
/// CommandPlan JSON. Includes:
/// - Base instructions for JSON-only output
/// - CommandPlan schema documentation with field descriptions
/// - Example request/response pairs
/// - User's shell context (shell type, git status, project info)
/// - Optional prompt extensions (SLY_PROMPT_EXTEND)
/// - Optional terminal snapshot for visual context
///
/// Parameters:
/// - `allocator`: Allocator for the returned string
/// - `context`: Shell context string from context.buildContext()
/// - `extend`: Optional additional instructions to append
/// - `snapshot`: Optional terminal state for visual context
///
/// Returns: Owned system prompt string. Caller must free.
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

/// Load AI provider configuration from environment variables.
///
/// Reads all relevant environment variables to construct a Config struct
/// suitable for passing to generate() or generatePlan(). Auto-detects
/// the best provider if not explicitly set.
///
/// Environment variables read:
/// - SLY_PROVIDER: Force specific provider ("anthropic", "openai", etc.)
/// - ANTHROPIC_API_KEY, SLY_ANTHROPIC_MODEL
/// - OPENAI_API_KEY, SLY_OPENAI_MODEL, SLY_OPENAI_URL
/// - GEMINI_API_KEY, SLY_GEMINI_MODEL
/// - SLY_OLLAMA_MODEL, SLY_OLLAMA_URL
///
/// Parameters:
/// - `allocator`: Allocator for config strings
///
/// Returns: Populated Config struct. Caller must free with freeConfig().
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
///
/// Must be called to release memory allocated by loadConfigFromEnv().
/// After calling, the Config struct should not be used.
///
/// Parameters:
/// - `allocator`: Same allocator used for loadConfigFromEnv()
/// - `config`: Config struct to free
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

/// Validate that the configuration has required API keys for the selected provider.
///
/// Checks that the necessary credentials are present and appear valid.
/// Logs helpful error messages with instructions for obtaining keys.
///
/// Parameters:
/// - `config`: Configuration to validate
///
/// Returns: void on success
///
/// Errors:
/// - `error.MissingApiKey`: Required API key environment variable not set
/// - `error.InvalidApiKey`: API key appears malformed (too short)
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
/// This is the low-level entry point for command generation. Builds context,
/// constructs the system prompt, queries the AI provider, and returns the
/// raw response (expected to be CommandPlan JSON).
///
/// For most use cases, prefer `generatePlan()` which adds validation and retries.
///
/// On network errors with non-echo providers, automatically falls back to the
/// echo provider for graceful degradation (useful for testing/offline).
///
/// Parameters:
/// - `allocator`: Allocator for the returned string
/// - `query`: Natural language query (e.g., "list all files")
/// - `config`: Provider configuration from loadConfigFromEnv()
/// - `snapshot`: Optional terminal state for context
///
/// Returns: Raw AI response string (should be CommandPlan JSON). Caller must free.
///
/// Errors:
/// - `error.MissingApiKey`: No API key for selected provider
/// - `error.InvalidApiKey`: API key validation failed
/// - `error.Network`: Network connection failed (after fallback attempt)
/// - `error.Unavailable`: Provider service unavailable
/// - `error.BadResponse`: Provider returned unparseable response
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
/// High-level API for command generation with validation and retry logic.
/// Calls generate() to get JSON, then parses and validates against the
/// CommandPlan schema. Retries on validation failures up to max_retries times.
///
/// This is the recommended API for shell integration, as it guarantees
/// a valid, structured CommandPlan on success.
///
/// Parameters:
/// - `allocator`: Allocator for the returned CommandPlan
/// - `query`: Natural language query (e.g., "find all rust files")
/// - `config`: Provider configuration from loadConfigFromEnv()
/// - `max_retries`: Number of attempts before giving up (typically 3)
/// - `snapshot`: Optional terminal state for context
///
/// Returns: Validated CommandPlan struct. Caller must free with plan.deinit().
///
/// Errors:
/// - `error.ValidationFailed`: Could not generate valid JSON after max_retries
/// - All errors from generate()
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

/// Shell types supported for integration.
///
/// Represents the shells that sly can integrate with via plugin scripts.
/// Each shell has a different mechanism for intercepting `# query` lines
/// and replacing the command buffer with generated commands.
///
/// ## Detection
/// Use `detectShell()` to automatically determine the current shell from $SHELL.
///
/// ## Integration
/// Use `installShellIntegration()` to install the appropriate plugin.
pub const ShellType = enum {
    /// GNU Bash - Uses readline bindings and PROMPT_COMMAND.
    bash,

    /// Zsh - Uses preexec hooks and zle widgets.
    zsh,

    /// Fish - Uses event handlers and commandline builtin.
    fish,

    /// Unknown or unsupported shell.
    unknown,

    /// Parse a shell path or name into a ShellType.
    ///
    /// Extracts the basename from shell paths (e.g., "/bin/zsh" → "zsh")
    /// and maps to the corresponding enum value.
    ///
    /// Parameters:
    /// - `s`: Shell path or name string
    ///
    /// Returns: Corresponding ShellType, or .unknown if not recognized.
    pub fn fromString(s: []const u8) ShellType {
        const basename = std.fs.path.basename(s);
        if (std.mem.eql(u8, basename, "zsh")) return .zsh;
        if (std.mem.eql(u8, basename, "bash")) return .bash;
        if (std.mem.eql(u8, basename, "fish")) return .fish;
        return .unknown;
    }

    /// Convert ShellType to its string name.
    ///
    /// Returns the canonical name of the shell, suitable for display
    /// or use in file paths.
    pub fn toString(self: ShellType) []const u8 {
        return switch (self) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .unknown => "unknown",
        };
    }

    /// Get the RC file path relative to home directory.
    ///
    /// Returns the configuration file where shell initialization
    /// commands should be added for this shell type.
    ///
    /// Returns: Relative path from $HOME, or empty string for unknown.
    pub fn rcFile(self: ShellType) []const u8 {
        return switch (self) {
            .bash => ".bashrc",
            .zsh => ".zshrc",
            .fish => ".config/fish/config.fish",
            .unknown => "",
        };
    }

    /// Get the embedded plugin script content for this shell.
    ///
    /// Returns the compile-time embedded plugin script that implements
    /// the `# query` integration for this shell type.
    ///
    /// Returns: Plugin script content, or empty string for unknown.
    pub fn pluginContent(self: ShellType) []const u8 {
        return switch (self) {
            .bash => bash_plugin,
            .zsh => zsh_plugin,
            .fish => fish_plugin,
            .unknown => "",
        };
    }
};

/// Detect the current shell from the SHELL environment variable.
///
/// Reads $SHELL and parses it to determine which shell is in use.
/// This is the user's login shell, which may differ from the shell
/// running the current process.
///
/// Parameters:
/// - `allocator`: Allocator for temporary string operations
///
/// Returns: Detected ShellType, or .unknown if detection fails.
pub fn detectShell(allocator: std.mem.Allocator) ShellType {
    const shell_path = getEnvOpt(allocator, "SHELL") orelse return .unknown;
    defer allocator.free(shell_path);

    return ShellType.fromString(shell_path);
}

/// Install shell integration for the specified shell type.
///
/// Creates the plugin file in ~/.config/sly/ and optionally adds a source
/// line to the shell's RC file. After installation, users can restart their
/// shell or source the RC file to enable `# query` integration.
///
/// Installation steps:
/// 1. Create ~/.config/sly/ directory
/// 2. Write plugin file (e.g., sly.plugin.zsh)
/// 3. If auto_source: Add source line to RC file (if not already present)
///
/// Parameters:
/// - `allocator`: Allocator for path operations
/// - `shell`: Target shell type
/// - `auto_source`: If true, add source line to RC file
///
/// Errors:
/// - `error.UnsupportedShell`: Shell type is .unknown
/// - `error.NoHomeDir`: HOME environment variable not set
/// - File system errors from directory/file creation
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
        .fish => "sly.plugin.fish",
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
