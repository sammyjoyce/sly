/// Command Planner - Phase 5 Implementation
///
/// Executes declarative command plans through TerminalRuntime with validation and audit trails.
/// Provides the orchestration layer between LLM-generated CommandPlan JSON and the terminal
/// emulator, handling key injection, snapshot comparison, and policy enforcement.
///
/// See specs/01-CORE-ARCHITECTURE.md for the CommandPlan schema specification.
const std = @import("std");
const terminal_runtime = @import("terminal_runtime.zig");
const policy_engine = @import("policy_engine.zig");
const ghostty = @import("libghostty.zig");

/// Paste safety policy controlling how stdin data is handled during plan execution.
///
/// Used by the policy engine to determine whether paste operations require user
/// confirmation or should be automatically allowed/rejected.
pub const PastePolicy = enum {
    /// Execute paste without user confirmation (trusted input).
    auto,
    /// Require explicit user confirmation before pasting (default for untrusted input).
    needs_confirm,
    /// Never allow paste; reject the operation entirely.
    never,
};

/// Confirmation mode controlling plan execution behavior.
///
/// Determines whether the command planner should execute plans automatically,
/// show them for preview, or reject execution entirely.
pub const ConfirmMode = enum {
    /// Execute the plan immediately without user intervention.
    auto,
    /// Display the command for user review before execution.
    preview,
    /// Block execution entirely; plan will return `.blocked` outcome.
    reject,
};

/// Defines an expected pattern to match against terminal output after plan execution.
///
/// Expectations are used to validate that a command produced the expected result.
/// They can match literal substrings or simple regex patterns in the terminal framebuffer.
///
/// ## Example
/// ```zig
/// const exp = Expectation{
///     .pattern = "^SUCCESS",
///     .must_match = true,
///     .is_regex = true,
/// };
/// ```
pub const Expectation = struct {
    /// Pattern to search for in the terminal framebuffer/output.
    /// Interpreted as literal substring unless `is_regex` is true.
    pattern: []const u8,

    /// If true, the pattern must be found for success.
    /// If false, the pattern must NOT be found (negative assertion).
    must_match: bool = true,

    /// If true, interpret `pattern` as a simple regex with support for:
    /// `^` (start anchor), `$` (end anchor), `.*` (zero or more chars), `.+` (one or more chars).
    /// If false, `pattern` is matched as a literal substring.
    is_regex: bool = false,

    /// Match this expectation's pattern against the given text.
    ///
    /// Parameters:
    /// - `text`: The text content to search (typically terminal framebuffer content).
    ///
    /// Returns: true if the pattern matches according to `is_regex` mode.
    ///
    /// Note: For regex mode, only a subset of regex syntax is supported:
    /// `^`, `$`, `.`, `.*`, and `.+`. Full PCRE is not implemented.
    pub fn matches(self: Expectation, text: []const u8) bool {
        if (!self.is_regex) {
            return std.mem.indexOf(u8, text, self.pattern) != null;
        }
        return matchSimpleRegex(self.pattern, text);
    }
};

/// Simple regex pattern matcher supporting: ^ $ .* .+
/// Returns true if pattern matches anywhere in text (unless anchored with ^/$)
fn matchSimpleRegex(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;

    // Check for anchors
    const starts_with_caret = pattern.len > 0 and pattern[0] == '^';
    const ends_with_dollar = pattern.len > 0 and pattern[pattern.len - 1] == '$';

    // Get the actual pattern without anchors
    var actual_pattern = pattern;
    if (starts_with_caret) actual_pattern = actual_pattern[1..];
    if (ends_with_dollar and actual_pattern.len > 0) actual_pattern = actual_pattern[0 .. actual_pattern.len - 1];

    // Handle empty text
    if (text.len == 0) {
        // Empty text matches empty pattern, or patterns that can match empty (like .*)
        if (actual_pattern.len == 0) return true;
        // Check if pattern can match empty string (e.g., ".*")
        return canMatchEmpty(actual_pattern);
    }

    // If anchored at start, only try matching from position 0
    if (starts_with_caret) {
        return matchAtPosition(actual_pattern, text, 0, ends_with_dollar);
    }

    // Try matching at each position
    for (0..text.len) |start| {
        if (matchAtPosition(actual_pattern, text, start, ends_with_dollar)) {
            return true;
        }
    }

    // Also try empty match for patterns like ".*" at end of text
    if (canMatchEmpty(actual_pattern)) {
        return true;
    }

    return false;
}

/// Check if a pattern can match an empty string
fn canMatchEmpty(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + 1 < pattern.len and pattern[i] == '.' and pattern[i + 1] == '*') {
            // .* can match empty
            i += 2;
        } else {
            // Any other pattern element requires at least one char
            return false;
        }
    }
    return true;
}

/// Match pattern at specific position in text
fn matchAtPosition(pattern: []const u8, text: []const u8, start: usize, must_end: bool) bool {
    var pat_idx: usize = 0;
    var txt_idx: usize = start;

    while (pat_idx < pattern.len) {
        // Check for .* or .+
        if (pat_idx + 1 < pattern.len and pattern[pat_idx] == '.') {
            const next = pattern[pat_idx + 1];
            if (next == '*') {
                // .* - match zero or more of any character (greedy with backtracking)
                pat_idx += 2;
                const remaining_pattern = pattern[pat_idx..];

                // Try matching remaining pattern from each position (greedy: start from end)
                if (remaining_pattern.len == 0) {
                    // No more pattern - .* matches rest of text
                    if (must_end) {
                        return true; // .* can consume everything
                    }
                    return true;
                }

                // Try each position from current to end
                var try_pos = txt_idx;
                while (try_pos <= text.len) : (try_pos += 1) {
                    if (matchAtPosition(remaining_pattern, text, try_pos, must_end)) {
                        return true;
                    }
                }
                return false;
            } else if (next == '+') {
                // .+ - match one or more of any character
                if (txt_idx >= text.len) return false; // Need at least one char
                pat_idx += 2;
                txt_idx += 1; // Consume at least one char
                const remaining_pattern = pattern[pat_idx..];

                if (remaining_pattern.len == 0) {
                    if (must_end) {
                        return true;
                    }
                    return true;
                }

                // Try each position from current to end
                var try_pos = txt_idx;
                while (try_pos <= text.len) : (try_pos += 1) {
                    if (matchAtPosition(remaining_pattern, text, try_pos, must_end)) {
                        return true;
                    }
                }
                return false;
            }
        }

        // Check for single . (match any single char)
        if (pattern[pat_idx] == '.') {
            if (txt_idx >= text.len) return false;
            pat_idx += 1;
            txt_idx += 1;
            continue;
        }

        // Literal character match
        if (txt_idx >= text.len) return false;
        if (pattern[pat_idx] != text[txt_idx]) return false;
        pat_idx += 1;
        txt_idx += 1;
    }

    // Pattern consumed - check end anchor
    if (must_end) {
        // Must be at end of text or at newline
        return txt_idx >= text.len or text[txt_idx] == '\n';
    }

    return true;
}

/// Severity level for failure signals, determining how matches are handled.
///
/// Controls the plan outcome when a failure signal pattern is detected.
pub const FailureSeverity = enum {
    /// Log a warning but continue execution; does not affect outcome.
    warning,
    /// Mark as error; outcome depends on `exit_on_match` setting.
    err,
    /// Critical failure; always results in `.failed` outcome immediately.
    critical,
};

/// Defines a pattern that indicates command failure when detected in terminal output.
///
/// Failure signals are checked before expectations and can trigger early exit
/// from plan execution. Useful for detecting error messages, exceptions, or
/// other failure indicators in command output.
///
/// ## Example
/// ```zig
/// const signal = FailureSignal{
///     .pattern = "ERROR:",
///     .exit_on_match = true,
///     .severity = .err,
/// };
/// ```
pub const FailureSignal = struct {
    /// Pattern to search for in terminal output that indicates failure.
    pattern: []const u8,

    /// If true, matching this pattern causes immediate failure (`.failed` outcome).
    /// If false with `.err` severity, results in `.degraded` outcome instead.
    exit_on_match: bool = true,

    /// Severity level controlling how this signal affects plan execution.
    severity: FailureSeverity = .err,
};

/// Declarative command plan schema representing an LLM-generated command to execute.
///
/// A CommandPlan encapsulates all information needed to execute a shell command,
/// validate its output, and record an audit trail. Plans are typically generated
/// by an LLM provider from natural language queries and parsed from JSON.
///
/// ## Schema (see specs/01-CORE-ARCHITECTURE.md)
/// Required fields: `plan_id`, `command`
/// Optional fields: `args`, `env`, `stdin`, `paste_policy`, `confirm_mode`,
///                  `expectations`, `failure_signals`, `timeout_ms`, `retry_count`, `retry_delay_ms`
///
/// ## Memory Ownership
/// When created via `fromJson`, the CommandPlan owns all allocated strings.
/// Caller must call `deinit` to free memory when done.
pub const CommandPlan = struct {
    /// Unique identifier for this plan, used in audit trails and logging.
    plan_id: []const u8,

    /// Base command to execute (e.g., "git", "find", "echo").
    command: []const u8,

    /// Command arguments, passed after the base command.
    args: []const []const u8 = &.{},

    /// Environment variables to set for this command (key-value pairs).
    env: std.StringHashMap([]const u8),

    /// Standard input data to pipe to the command, if any.
    stdin: ?[]const u8 = null,

    /// Paste safety policy for stdin handling.
    paste_policy: PastePolicy = .needs_confirm,

    /// Confirmation mode controlling execution behavior.
    confirm_mode: ConfirmMode = .preview,

    /// Expected patterns to validate in terminal output after execution.
    expectations: std.ArrayList(Expectation),

    /// Failure patterns that indicate command failure.
    failure_signals: std.ArrayList(FailureSignal),

    /// Unix timestamp when this plan was created.
    created_at: i64 = 0,

    /// Number of retry attempts on `.failed` outcome (0 = no retries).
    retry_count: u8 = 0,

    /// Base delay between retries in milliseconds; doubles each attempt (exponential backoff).
    retry_delay_ms: u64 = 1000,

    /// Maximum execution time in milliseconds. Returns `.timeout` if exceeded.
    /// Null means no timeout limit.
    timeout_ms: ?u64 = null,

    /// Parse a CommandPlan from a JSON string.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for all string duplication. Caller retains ownership.
    /// - `json_str`: JSON string conforming to the CommandPlan schema.
    ///
    /// Returns: A fully-initialized CommandPlan that owns all its string data.
    ///
    /// Errors: Returns error on invalid JSON or missing required fields (`plan_id`, `command`).
    ///
    /// Memory: Caller must call `deinit` on the returned plan to free memory.
    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !CommandPlan {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json_str,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract required fields
        const plan_id = root.get("plan_id").?.string;
        const command = root.get("command").?.string;

        // Create env hashmap
        var env = std.StringHashMap([]const u8).init(allocator);
        errdefer env.deinit();

        if (root.get("env")) |env_obj| {
            var it = env_obj.object.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                const val_copy = try allocator.dupe(u8, entry.value_ptr.*.string);
                try env.put(key_copy, val_copy);
            }
        }

        // Extract optional arrays
        var args: std.ArrayList([]const u8) = .{};
        if (root.get("args")) |args_arr| {
            for (args_arr.array.items) |arg| {
                try args.append(allocator, try allocator.dupe(u8, arg.string));
            }
        }

        // Parse expectations array
        var expectations: std.ArrayList(Expectation) = .{};
        errdefer {
            for (expectations.items) |exp| {
                allocator.free(exp.pattern);
            }
            expectations.deinit(allocator);
        }
        if (root.get("expectations")) |exp_val| {
            if (exp_val == .array) {
                for (exp_val.array.items) |item| {
                    if (item == .object) {
                        const exp_obj = item.object;
                        const pattern = if (exp_obj.get("pattern")) |p| switch (p) {
                            .string => |s| try allocator.dupe(u8, s),
                            else => continue,
                        } else continue;

                        const must_match = if (exp_obj.get("must_match")) |m| switch (m) {
                            .bool => |b| b,
                            else => true,
                        } else true;

                        const is_regex = if (exp_obj.get("is_regex")) |r| switch (r) {
                            .bool => |b| b,
                            else => false,
                        } else false;

                        try expectations.append(allocator, .{
                            .pattern = pattern,
                            .must_match = must_match,
                            .is_regex = is_regex,
                        });
                    }
                }
            }
        }

        // Parse failure_signals array
        var failure_signals: std.ArrayList(FailureSignal) = .{};
        errdefer {
            for (failure_signals.items) |sig| {
                allocator.free(sig.pattern);
            }
            failure_signals.deinit(allocator);
        }
        if (root.get("failure_signals")) |sig_val| {
            if (sig_val == .array) {
                for (sig_val.array.items) |item| {
                    if (item == .object) {
                        const sig_obj = item.object;
                        const pattern = if (sig_obj.get("pattern")) |p| switch (p) {
                            .string => |s| try allocator.dupe(u8, s),
                            else => continue,
                        } else continue;

                        const exit_on_match = if (sig_obj.get("exit_on_match")) |e| switch (e) {
                            .bool => |b| b,
                            else => true,
                        } else true;

                        const severity = if (sig_obj.get("severity")) |sev| switch (sev) {
                            .string => |s| std.meta.stringToEnum(FailureSeverity, s) orelse .err,
                            else => .err,
                        } else .err;

                        try failure_signals.append(allocator, .{
                            .pattern = pattern,
                            .exit_on_match = exit_on_match,
                            .severity = severity,
                        });
                    }
                }
            }
        }

        return CommandPlan{
            .plan_id = try allocator.dupe(u8, plan_id),
            .command = try allocator.dupe(u8, command),
            .args = try args.toOwnedSlice(allocator),
            .env = env,
            .stdin = blk: {
                if (root.get("stdin")) |s| {
                    if (s == .null) break :blk null;
                    break :blk try allocator.dupe(u8, s.string);
                }
                break :blk null;
            },
            .paste_policy = if (root.get("paste_policy")) |p|
                std.meta.stringToEnum(PastePolicy, p.string) orelse .needs_confirm
            else
                .needs_confirm,
            .confirm_mode = if (root.get("confirm_mode")) |c|
                std.meta.stringToEnum(ConfirmMode, c.string) orelse .preview
            else
                .preview,
            .expectations = expectations,
            .failure_signals = failure_signals,
            .created_at = std.time.timestamp(),
            .timeout_ms = blk: {
                if (root.get("timeout_ms")) |t| {
                    if (t == .integer) break :blk @intCast(t.integer);
                }
                break :blk null;
            },
            .retry_count = blk: {
                if (root.get("retry_count")) |rc| {
                    if (rc == .integer) break :blk @intCast(rc.integer);
                }
                break :blk 0;
            },
            .retry_delay_ms = blk: {
                if (root.get("retry_delay_ms")) |rd| {
                    if (rd == .integer) break :blk @intCast(rd.integer);
                }
                break :blk 1000;
            },
        };
    }

    /// Free all memory owned by this CommandPlan.
    ///
    /// Parameters:
    /// - `allocator`: The same allocator used to create this plan via `fromJson`.
    ///
    /// After calling, the CommandPlan is invalid and must not be used.
    pub fn deinit(self: *CommandPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);
        allocator.free(self.command);
        for (self.args) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.args);

        var it = self.env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();

        if (self.stdin) |stdin| {
            allocator.free(stdin);
        }

        for (self.expectations.items) |exp| {
            allocator.free(exp.pattern);
        }
        self.expectations.deinit(allocator);

        for (self.failure_signals.items) |sig| {
            allocator.free(sig.pattern);
        }
        self.failure_signals.deinit(allocator);
    }

    /// Serialize this CommandPlan to a compact JSON string.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for the output string.
    ///
    /// Returns: Owned JSON string that caller must free.
    ///
    /// Note: For pretty-printed output, use `toJsonWithOptions` with `pretty: true`.
    pub fn toJson(self: CommandPlan, allocator: std.mem.Allocator) ![]const u8 {
        return self.toJsonWithOptions(allocator, .{});
    }

    /// Options for JSON serialization output format.
    pub const JsonOptions = struct {
        /// If true, output human-readable JSON with indentation and newlines.
        pretty: bool = false,
    };

    /// Serialize this CommandPlan to JSON with configurable formatting.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for the output string.
    /// - `options`: Formatting options (e.g., pretty-print).
    ///
    /// Returns: Owned JSON string that caller must free.
    pub fn toJsonWithOptions(self: CommandPlan, allocator: std.mem.Allocator, options: JsonOptions) ![]const u8 {
        var output = std.ArrayList(u8){};
        errdefer output.deinit(allocator);

        const nl = if (options.pretty) "\n" else "";
        const indent1 = if (options.pretty) "  " else "";
        const indent2 = if (options.pretty) "    " else "";
        const sp = if (options.pretty) " " else "";

        try output.append(allocator, '{');
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"plan_id\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '"');
        try output.appendSlice(allocator, self.plan_id);
        try output.appendSlice(allocator, "\",");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"command\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '"');
        try output.appendSlice(allocator, self.command);
        try output.appendSlice(allocator, "\",");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"args\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '[');

        // Args array
        for (self.args, 0..) |arg, i| {
            if (i > 0) try output.append(allocator, ',');
            try output.append(allocator, '"');
            try output.appendSlice(allocator, arg);
            try output.append(allocator, '"');
        }
        try output.appendSlice(allocator, "],");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"env\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '{');

        // Env object
        var env_iter = self.env.iterator();
        var first_env = true;
        while (env_iter.next()) |entry| {
            if (!first_env) try output.append(allocator, ',');
            try output.append(allocator, '"');
            try output.appendSlice(allocator, entry.key_ptr.*);
            try output.appendSlice(allocator, "\":");
            try output.appendSlice(allocator, sp);
            try output.append(allocator, '"');
            try output.appendSlice(allocator, entry.value_ptr.*);
            try output.append(allocator, '"');
            first_env = false;
        }
        try output.appendSlice(allocator, "},");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"stdin\":");
        try output.appendSlice(allocator, sp);

        // Stdin
        if (self.stdin) |stdin| {
            try output.append(allocator, '"');
            try output.appendSlice(allocator, stdin);
            try output.append(allocator, '"');
        } else {
            try output.appendSlice(allocator, "null");
        }

        // Policies and modes
        try output.append(allocator, ',');
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"paste_policy\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '"');
        try output.appendSlice(allocator, @tagName(self.paste_policy));
        try output.appendSlice(allocator, "\",");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"confirm_mode\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '"');
        try output.appendSlice(allocator, @tagName(self.confirm_mode));
        try output.appendSlice(allocator, "\",");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"expectations\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '[');

        for (self.expectations.items, 0..) |exp, i| {
            if (i > 0) try output.append(allocator, ',');
            try output.appendSlice(allocator, nl);
            try output.appendSlice(allocator, indent2);
            try output.appendSlice(allocator, "{\"pattern\":");
            try output.appendSlice(allocator, sp);
            try output.append(allocator, '"');
            for (exp.pattern) |c| {
                switch (c) {
                    '"' => try output.appendSlice(allocator, "\\\""),
                    '\\' => try output.appendSlice(allocator, "\\\\"),
                    '\n' => try output.appendSlice(allocator, "\\n"),
                    '\r' => try output.appendSlice(allocator, "\\r"),
                    '\t' => try output.appendSlice(allocator, "\\t"),
                    else => try output.append(allocator, c),
                }
            }
            try output.appendSlice(allocator, "\",");
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, "\"must_match\":");
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, if (exp.must_match) "true" else "false");
            try output.append(allocator, ',');
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, "\"is_regex\":");
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, if (exp.is_regex) "true" else "false");
            try output.append(allocator, '}');
        }

        if (self.expectations.items.len > 0 and options.pretty) {
            try output.appendSlice(allocator, nl);
            try output.appendSlice(allocator, indent1);
        }
        try output.appendSlice(allocator, "],");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"failure_signals\":");
        try output.appendSlice(allocator, sp);
        try output.append(allocator, '[');

        for (self.failure_signals.items, 0..) |sig, i| {
            if (i > 0) try output.append(allocator, ',');
            try output.appendSlice(allocator, nl);
            try output.appendSlice(allocator, indent2);
            try output.appendSlice(allocator, "{\"pattern\":");
            try output.appendSlice(allocator, sp);
            try output.append(allocator, '"');
            for (sig.pattern) |c| {
                switch (c) {
                    '"' => try output.appendSlice(allocator, "\\\""),
                    '\\' => try output.appendSlice(allocator, "\\\\"),
                    '\n' => try output.appendSlice(allocator, "\\n"),
                    '\r' => try output.appendSlice(allocator, "\\r"),
                    '\t' => try output.appendSlice(allocator, "\\t"),
                    else => try output.append(allocator, c),
                }
            }
            try output.appendSlice(allocator, "\",");
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, "\"exit_on_match\":");
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, if (sig.exit_on_match) "true" else "false");
            try output.append(allocator, ',');
            try output.appendSlice(allocator, sp);
            try output.appendSlice(allocator, "\"severity\":");
            try output.appendSlice(allocator, sp);
            try output.append(allocator, '"');
            try output.appendSlice(allocator, @tagName(sig.severity));
            try output.append(allocator, '"');
            try output.append(allocator, '}');
        }

        if (self.failure_signals.items.len > 0 and options.pretty) {
            try output.appendSlice(allocator, nl);
            try output.appendSlice(allocator, indent1);
        }
        try output.appendSlice(allocator, "],");
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"created_at\":");
        try output.appendSlice(allocator, sp);

        // Timestamp
        var buf: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&buf, "{d}", .{self.created_at});
        try output.appendSlice(allocator, timestamp_str);
        try output.append(allocator, ',');
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"timeout_ms\":");
        try output.appendSlice(allocator, sp);

        // Timeout
        if (self.timeout_ms) |timeout| {
            var timeout_buf: [32]u8 = undefined;
            const timeout_str = try std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout});
            try output.appendSlice(allocator, timeout_str);
        } else {
            try output.appendSlice(allocator, "null");
        }
        try output.append(allocator, ',');
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"retry_count\":");
        try output.appendSlice(allocator, sp);

        // Retry count
        var retry_count_buf: [32]u8 = undefined;
        const retry_count_str = try std.fmt.bufPrint(&retry_count_buf, "{d}", .{self.retry_count});
        try output.appendSlice(allocator, retry_count_str);
        try output.append(allocator, ',');
        try output.appendSlice(allocator, nl);
        try output.appendSlice(allocator, indent1);
        try output.appendSlice(allocator, "\"retry_delay_ms\":");
        try output.appendSlice(allocator, sp);

        // Retry delay
        var retry_delay_buf: [32]u8 = undefined;
        const retry_delay_str = try std.fmt.bufPrint(&retry_delay_buf, "{d}", .{self.retry_delay_ms});
        try output.appendSlice(allocator, retry_delay_str);
        try output.appendSlice(allocator, nl);
        try output.append(allocator, '}');

        return output.toOwnedSlice(allocator);
    }
};

/// Result of plan execution, indicating success, failure mode, or policy block.
///
/// Returned by `CommandPlanner.executePlan` to indicate how the plan completed.
pub const PlanOutcome = enum {
    /// Plan executed successfully; all expectations met, no failure signals detected.
    success,
    /// Partial success; some expectations unmet but no critical failures.
    degraded,
    /// Execution was blocked by policy (e.g., `confirm_mode == .reject`).
    blocked,
    /// Failure signals were detected in terminal output.
    failed,
    /// Execution exceeded `timeout_ms` duration.
    timeout,
};

/// Audit record capturing the complete execution trace of a plan.
///
/// Contains snapshots before/after execution, keystream hash for reproducibility,
/// OSC events, paste verdicts, and any error messages. Used for debugging,
/// compliance logging, and post-hoc analysis of command execution.
///
/// ## Memory Ownership
/// PlanAudit owns all its string data. Caller must call `deinit` to free.
pub const PlanAudit = struct {
    /// The plan_id of the executed plan (copied from CommandPlan).
    plan_id: []const u8,

    /// Final outcome of the plan execution.
    outcome: PlanOutcome,

    /// Wyhash of the keystream bytes sent to the PTY, for reproducibility verification.
    keystream_hash: u64,

    /// JSON-serialized terminal snapshot captured before command execution.
    snapshot_before: ?[]const u8 = null,

    /// JSON-serialized terminal snapshot captured after command execution.
    snapshot_after: ?[]const u8 = null,

    /// OSC escape sequence events recorded during execution.
    osc_events: std.ArrayList([]const u8),

    /// Paste operation verdicts (allowed/rejected) recorded during execution.
    paste_verdicts: std.ArrayList([]const u8),

    /// Unix timestamp when the audit was created.
    timestamp: i64,

    /// Human-readable error message if execution failed, degraded, or was blocked.
    error_message: ?[]const u8 = null,

    /// Initialize a new audit record for a plan.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for string storage.
    /// - `plan_id`: The plan identifier to copy into this audit.
    ///
    /// Returns: A new PlanAudit with default `.success` outcome.
    pub fn init(allocator: std.mem.Allocator, plan_id: []const u8) !PlanAudit {
        return PlanAudit{
            .plan_id = try allocator.dupe(u8, plan_id),
            .outcome = .success,
            .keystream_hash = 0,
            .osc_events = .{},
            .paste_verdicts = .{},
            .timestamp = std.time.timestamp(),
        };
    }

    /// Free all memory owned by this audit record.
    ///
    /// Parameters:
    /// - `allocator`: The same allocator used in `init`.
    pub fn deinit(self: *PlanAudit, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);

        if (self.snapshot_before) |s| allocator.free(s);
        if (self.snapshot_after) |s| allocator.free(s);
        if (self.error_message) |e| allocator.free(e);

        for (self.osc_events.items) |event| {
            allocator.free(event);
        }
        self.osc_events.deinit(allocator);

        for (self.paste_verdicts.items) |verdict| {
            allocator.free(verdict);
        }
        self.paste_verdicts.deinit(allocator);
    }
};

/// Orchestrates execution of declarative command plans through TerminalRuntime.
///
/// The CommandPlanner is responsible for:
/// - Building command strings from plan specifications
/// - Injecting keystrokes into the terminal emulator
/// - Capturing before/after snapshots for comparison
/// - Validating output against expectations and failure signals
/// - Recording audit trails for all executions
///
/// ## Usage
/// ```zig
/// var planner = CommandPlanner.init(allocator, &runtime);
/// defer planner.deinit();
///
/// const outcome = try planner.executePlan(&plan);
/// const audits = planner.getAudits();
/// ```
pub const CommandPlanner = struct {
    allocator: std.mem.Allocator,
    runtime: *terminal_runtime.TerminalRuntime,

    /// Accumulated audit records for all executed plans.
    audits: std.ArrayList(PlanAudit),

    /// Create a new CommandPlanner attached to a TerminalRuntime.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for internal storage (audits, strings).
    /// - `runtime`: Pointer to an initialized TerminalRuntime for key injection and snapshots.
    ///
    /// Returns: An initialized CommandPlanner ready to execute plans.
    pub fn init(allocator: std.mem.Allocator, runtime: *terminal_runtime.TerminalRuntime) CommandPlanner {
        return CommandPlanner{
            .allocator = allocator,
            .runtime = runtime,
            .audits = .{},
        };
    }

    /// Free all resources owned by this CommandPlanner, including all audit records.
    pub fn deinit(self: *CommandPlanner) void {
        for (self.audits.items) |*audit| {
            audit.deinit(self.allocator);
        }
        self.audits.deinit(self.allocator);
    }

    /// Execute a declarative command plan and record an audit trail.
    ///
    /// This is the main entry point for plan execution. The method:
    /// 1. Checks confirmation mode and paste policies
    /// 2. Captures a before-snapshot of terminal state
    /// 3. Builds the command string and injects it as keystrokes
    /// 4. Captures an after-snapshot
    /// 5. Compares output against expectations and failure signals
    /// 6. Records a PlanAudit with the complete execution trace
    ///
    /// Parameters:
    /// - `plan`: The CommandPlan to execute (not modified).
    ///
    /// Returns: The execution outcome (success, degraded, blocked, failed, or timeout).
    ///
    /// The audit is always recorded regardless of outcome. Access via `getAudits()`.
    pub fn executePlan(self: *CommandPlanner, plan: *const CommandPlan) !PlanOutcome {
        std.log.info("Executing plan: {s}", .{plan.plan_id});

        // Record start time for timeout tracking
        const start_time = std.time.milliTimestamp();

        // Create audit record
        var audit = try PlanAudit.init(self.allocator, plan.plan_id);
        errdefer audit.deinit(self.allocator);

        // Check confirmation mode
        if (plan.confirm_mode == .reject) {
            audit.outcome = .blocked;
            audit.error_message = try self.allocator.dupe(u8, "Plan blocked by reject confirm_mode");
            try self.audits.append(self.allocator, audit);
            std.log.warn("Plan {s} blocked by policy", .{plan.plan_id});
            return .blocked;
        }

        // Check timeout before snapshot
        if (plan.timeout_ms) |timeout| {
            const elapsed: u64 = @intCast(std.time.milliTimestamp() - start_time);
            if (elapsed >= timeout) {
                audit.outcome = .timeout;
                audit.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Execution timeout: {d}ms exceeded before snapshot",
                    .{timeout},
                );
                try self.audits.append(self.allocator, audit);
                std.log.warn("Plan {s} timed out", .{plan.plan_id});
                return .timeout;
            }
        }

        // Capture snapshot before execution
        audit.snapshot_before = try self.captureSnapshot(.{});

        // Build command string
        const command_str = try self.buildCommandString(plan);
        defer self.allocator.free(command_str);

        std.log.debug("Command to execute: {s}", .{command_str});

        // Check timeout before stdin handling
        if (plan.timeout_ms) |timeout| {
            const elapsed: u64 = @intCast(std.time.milliTimestamp() - start_time);
            if (elapsed >= timeout) {
                audit.outcome = .timeout;
                audit.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Execution timeout: {d}ms exceeded before stdin handling",
                    .{timeout},
                );
                try self.audits.append(self.allocator, audit);
                std.log.warn("Plan {s} timed out", .{plan.plan_id});
                return .timeout;
            }
        }

        // Handle stdin paste if present
        if (plan.stdin) |stdin_data| {
            var paste_result = try self.runtime.enqueuePaste(stdin_data);
            defer paste_result.deinit(self.allocator);

            if (paste_result.verdict == .rejected) {
                audit.outcome = .blocked;
                audit.error_message = try self.allocator.dupe(u8, paste_result.rationale);
                try self.audits.append(self.allocator, audit);
                std.log.warn("Plan {s} blocked by paste policy: {s}", .{ plan.plan_id, paste_result.rationale });
                return .blocked;
            }

            // Record paste verdict
            const verdict_msg = try std.fmt.allocPrint(
                self.allocator,
                "Paste verdict: {s} - {s}",
                .{ @tagName(paste_result.verdict), paste_result.rationale },
            );
            try audit.paste_verdicts.append(self.allocator, verdict_msg);
        }

        // Check timeout before key injection
        if (plan.timeout_ms) |timeout| {
            const elapsed: u64 = @intCast(std.time.milliTimestamp() - start_time);
            if (elapsed >= timeout) {
                audit.outcome = .timeout;
                audit.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Execution timeout: {d}ms exceeded before key injection",
                    .{timeout},
                );
                try self.audits.append(self.allocator, audit);
                std.log.warn("Plan {s} timed out", .{plan.plan_id});
                return .timeout;
            }
        }

        // Inject command as keystrokes
        const keystream = try self.injectCommandAsKeys(command_str);
        defer self.allocator.free(keystream);

        // Compute keystream hash for audit
        audit.keystream_hash = std.hash.Wyhash.hash(0, keystream);
        std.log.debug("Keystream hash: {x}", .{audit.keystream_hash});

        // Simulate Enter key to execute (in real implementation, this would be PTY write)
        _ = try self.runtime.injectKey(
            ghostty.KEY_ACTION_PRESS,
            13, // Enter key
            0, // No modifiers
        );

        // Check timeout before final snapshot
        if (plan.timeout_ms) |timeout| {
            const elapsed: u64 = @intCast(std.time.milliTimestamp() - start_time);
            if (elapsed >= timeout) {
                audit.outcome = .timeout;
                audit.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Execution timeout: {d}ms exceeded after {d}ms",
                    .{ timeout, elapsed },
                );
                try self.audits.append(self.allocator, audit);
                std.log.warn("Plan {s} timed out", .{plan.plan_id});
                return .timeout;
            }
        }

        // Capture snapshot after execution
        audit.snapshot_after = try self.captureSnapshot(.{});

        // Compare snapshots against expectations and failure signals
        const comparison_result = try self.compareSnapshot(
            audit.snapshot_after,
            plan.expectations.items,
            plan.failure_signals.items,
        );

        // Set outcome based on comparison
        audit.outcome = comparison_result.outcome;
        audit.error_message = comparison_result.error_message;

        try self.audits.append(self.allocator, audit);

        if (audit.outcome == .success) {
            std.log.info("Plan {s} executed successfully", .{plan.plan_id});
        } else {
            std.log.warn("Plan {s} finished with outcome: {s}", .{ plan.plan_id, @tagName(audit.outcome) });
        }

        return audit.outcome;
    }

    /// Execute a plan with automatic retry on failure using exponential backoff.
    ///
    /// Calls `executePlan` and retries on `.failed` outcome up to `plan.retry_count` times.
    /// Delay between retries starts at `plan.retry_delay_ms` and doubles each attempt.
    ///
    /// Parameters:
    /// - `plan`: The CommandPlan to execute.
    ///
    /// Returns: Final outcome after all retry attempts (or first non-failed outcome).
    ///
    /// Note: Each attempt generates a separate audit record.
    pub fn executePlanWithRetry(self: *CommandPlanner, plan: *const CommandPlan) !PlanOutcome {
        var attempt: u8 = 0;
        var current_delay_ms = plan.retry_delay_ms;

        while (true) {
            const outcome = try self.executePlan(plan);

            if (outcome != .failed or attempt >= plan.retry_count) {
                return outcome;
            }

            std.log.info("Plan {s} failed, retrying in {d}ms (attempt {d}/{d})", .{
                plan.plan_id,
                current_delay_ms,
                attempt + 1,
                plan.retry_count,
            });

            std.time.sleep(current_delay_ms * std.time.ns_per_ms);

            attempt += 1;
            current_delay_ms *= 2;
        }
    }

    /// Build the full command string from a plan's command, args, and environment.
    ///
    /// Constructs a shell-ready string: `ENV1=val1 ENV2=val2 command arg1 arg2 ...`
    ///
    /// Parameters:
    /// - `plan`: The CommandPlan containing command, args, and env.
    ///
    /// Returns: Owned string that caller must free.
    pub fn buildCommandString(self: *CommandPlanner, plan: *const CommandPlan) ![]const u8 {
        var parts: std.ArrayList(u8) = .{};
        defer parts.deinit(self.allocator);

        const writer = parts.writer(self.allocator);

        // Add environment variables
        var env_it = plan.env.iterator();
        while (env_it.next()) |entry| {
            try writer.print("{s}={s} ", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Add command
        try writer.writeAll(plan.command);

        // Add arguments
        for (plan.args) |arg| {
            try writer.print(" {s}", .{arg});
        }

        return try parts.toOwnedSlice(self.allocator);
    }

    /// Inject command string as keystrokes
    fn injectCommandAsKeys(self: *CommandPlanner, command: []const u8) ![]const u8 {
        var keystream: std.ArrayList(u8) = .{};
        defer keystream.deinit(self.allocator);

        // For each character, inject as keystroke and collect output
        for (command) |char| {
            const encoded = try self.runtime.injectKey(
                ghostty.KEY_ACTION_PRESS,
                char,
                0, // No modifiers for regular chars
            );
            defer self.allocator.free(encoded);

            // Accumulate encoded bytes
            try keystream.appendSlice(self.allocator, encoded);
        }

        return try keystream.toOwnedSlice(self.allocator);
    }

    /// Result from snapshot comparison
    const ComparisonResult = struct {
        outcome: PlanOutcome,
        error_message: ?[]const u8 = null,
    };

    /// Compare terminal snapshot against expectations and failure signals.
    ///
    /// Checks failure signals first (by severity: critical > err > warning),
    /// then validates expectations. Returns appropriate outcome based on matches.
    ///
    /// Parameters:
    /// - `snapshot_str`: Serialized snapshot JSON (currently unused, will use runtime snapshot).
    /// - `expectations`: Patterns that must/must-not match for success.
    /// - `failure_signals`: Patterns that indicate command failure.
    ///
    /// Returns: ComparisonResult with outcome and optional error message.
    pub fn compareSnapshot(
        self: *CommandPlanner,
        snapshot_str: ?[]const u8,
        expectations: []const Expectation,
        failure_signals: []const FailureSignal,
    ) !ComparisonResult {
        _ = snapshot_str; // Will use once we have full snapshot serialization

        // Get actual snapshot for pattern matching
        var snapshot = try self.runtime.snapshot(.{});
        defer snapshot.deinit(self.allocator);

        // First, check for failure signals (highest priority)
        // Process by severity: critical first, then err, then warning
        for (failure_signals) |signal| {
            if (try self.matchPattern(signal.pattern, &snapshot)) {
                switch (signal.severity) {
                    .critical => {
                        // Critical: Always fail immediately
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Critical failure signal detected: {s}",
                            .{signal.pattern},
                        );
                        return ComparisonResult{
                            .outcome = .failed,
                            .error_message = msg,
                        };
                    },
                    .err => {
                        // Error: Fail unless exit_on_match is false (lenient mode)
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Error failure signal detected: {s} (exit_on_match: {})",
                            .{ signal.pattern, signal.exit_on_match },
                        );
                        return ComparisonResult{
                            .outcome = if (signal.exit_on_match) .failed else .degraded,
                            .error_message = msg,
                        };
                    },
                    .warning => {
                        // Warning: Log but continue
                        std.log.warn("Warning signal detected: {s}", .{signal.pattern});
                        // Continue checking other signals and expectations
                    },
                }
            }
        }

        // Then check expectations
        for (expectations) |expectation| {
            const matched = try self.matchExpectation(expectation, &snapshot);
            if (expectation.must_match and !matched) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Expectation not met: pattern '{s}' not found in output",
                    .{expectation.pattern},
                );
                std.log.warn("{s}", .{msg});
                return ComparisonResult{
                    .outcome = .degraded,
                    .error_message = msg,
                };
            } else if (!expectation.must_match and matched) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Expectation not met: pattern '{s}' should not be in output",
                    .{expectation.pattern},
                );
                std.log.warn("{s}", .{msg});
                return ComparisonResult{
                    .outcome = .degraded,
                    .error_message = msg,
                };
            }
        }

        // All checks passed
        return ComparisonResult{
            .outcome = .success,
            .error_message = null,
        };
    }

    /// Match a pattern against snapshot framebuffer content
    fn matchPattern(self: *CommandPlanner, pattern: []const u8, snapshot: *const terminal_runtime.Snapshot) !bool {
        return self.matchPatternWithRegex(pattern, false, snapshot);
    }

    /// Match a pattern against snapshot with optional regex support
    fn matchPatternWithRegex(self: *CommandPlanner, pattern: []const u8, is_regex: bool, snapshot: *const terminal_runtime.Snapshot) !bool {
        // Build text content from framebuffer
        var content: std.ArrayList(u8) = .{};
        defer content.deinit(self.allocator);

        for (snapshot.framebuffer) |row| {
            for (row) |cell| {
                try content.append(self.allocator, cell.char);
            }
            try content.append(self.allocator, '\n');
        }

        const text = content.items;

        const exp = Expectation{ .pattern = pattern, .must_match = true, .is_regex = is_regex };
        return exp.matches(text);
    }

    /// Match expectation against snapshot using its is_regex flag
    fn matchExpectation(self: *CommandPlanner, expectation: Expectation, snapshot: *const terminal_runtime.Snapshot) !bool {
        return self.matchPatternWithRegex(expectation.pattern, expectation.is_regex, snapshot);
    }

    /// Capture current terminal snapshot
    fn captureSnapshot(self: *CommandPlanner, options: terminal_runtime.SnapshotOptions) ![]const u8 {
        var snapshot = try self.runtime.snapshot(options);
        defer snapshot.deinit(self.allocator);

        return try serializeSnapshot(self.allocator, &snapshot);
    }

    /// Serialize a terminal snapshot to JSON format for audit trails.
    ///
    /// Produces a compact JSON object containing hash, timestamp, dimensions,
    /// cursor state, and content (up to 20 non-empty lines).
    ///
    /// Parameters:
    /// - `allocator`: Allocator for output string.
    /// - `snapshot`: Terminal snapshot to serialize.
    ///
    /// Returns: Owned JSON string that caller must free.
    pub fn serializeSnapshot(allocator: std.mem.Allocator, snapshot: *const terminal_runtime.Snapshot) ![]const u8 {
        var content_buf: std.ArrayList(u8) = .{};
        defer content_buf.deinit(allocator);

        var line_count: usize = 0;
        const max_lines: usize = 20;

        for (snapshot.framebuffer) |row| {
            if (line_count >= max_lines) break;

            var has_content = false;
            for (row) |cell| {
                if (cell.char != ' ' and cell.char != 0) {
                    has_content = true;
                    break;
                }
            }
            if (!has_content) continue;

            if (content_buf.items.len > 0) {
                try content_buf.append(allocator, '\n');
            }

            for (row) |cell| {
                if (cell.char != 0) {
                    try content_buf.append(allocator, cell.char);
                }
            }
            while (content_buf.items.len > 0 and content_buf.items[content_buf.items.len - 1] == ' ') {
                _ = content_buf.pop();
            }
            line_count += 1;
        }

        var json_buf: std.ArrayList(u8) = .{};
        errdefer json_buf.deinit(allocator);

        const writer = json_buf.writer(allocator);
        try writer.writeAll("{\"hash\":\"");
        try std.fmt.format(writer, "{x}", .{snapshot.hash});
        try writer.writeAll("\",\"timestamp\":");
        try std.fmt.format(writer, "{}", .{snapshot.timestamp});
        try writer.writeAll(",\"rows\":");
        try std.fmt.format(writer, "{}", .{snapshot.rows});
        try writer.writeAll(",\"cols\":");
        try std.fmt.format(writer, "{}", .{snapshot.cols});
        try writer.writeAll(",\"cursor\":{\"row\":");
        try std.fmt.format(writer, "{}", .{snapshot.cursor_row});
        try writer.writeAll(",\"col\":");
        try std.fmt.format(writer, "{}", .{snapshot.cursor_col});
        try writer.writeAll(",\"visible\":");
        try writer.writeAll(if (snapshot.cursor_visible) "true" else "false");
        try writer.writeAll("},\"content\":\"");

        for (content_buf.items) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c >= 0x20 and c < 0x7F) {
                        try writer.writeByte(c);
                    } else {
                        try std.fmt.format(writer, "\\u{x:0>4}", .{c});
                    }
                },
            }
        }
        try writer.writeAll("\",\"lines\":");
        try std.fmt.format(writer, "{}", .{line_count});
        try writer.writeAll("}");

        return json_buf.toOwnedSlice(allocator);
    }

    /// Get all accumulated audit records from executed plans.
    ///
    /// Returns: Slice of PlanAudit records in execution order.
    ///
    /// Note: The returned slice is valid until `deinit` is called on the planner.
    /// Do not free individual audits; they are owned by the CommandPlanner.
    pub fn getAudits(self: *const CommandPlanner) []const PlanAudit {
        return self.audits.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "command plan - parse from JSON" {
    const testing = std.testing;

    const json =
        \\{
        \\  "plan_id": "test-123",
        \\  "command": "echo",
        \\  "args": ["hello", "world"],
        \\  "env": {"FOO": "bar"},
        \\  "paste_policy": "auto",
        \\  "confirm_mode": "preview"
        \\}
    ;

    var plan = try CommandPlan.fromJson(testing.allocator, json);
    defer plan.deinit(testing.allocator);

    try testing.expectEqualStrings("test-123", plan.plan_id);
    try testing.expectEqualStrings("echo", plan.command);
    try testing.expectEqual(@as(usize, 2), plan.args.len);
    try testing.expectEqualStrings("hello", plan.args[0]);
    try testing.expectEqualStrings("world", plan.args[1]);
    try testing.expectEqual(PastePolicy.auto, plan.paste_policy);
    try testing.expectEqual(ConfirmMode.preview, plan.confirm_mode);
}

test "fromJson parses expectations and failure_signals" {
    const json =
        \\{"plan_id":"test-1","command":"echo","args":["test"],
        \\"expectations":[{"pattern":"test","must_match":true}],
        \\"failure_signals":[{"pattern":"error","exit_on_match":true}]}
    ;

    var plan = try CommandPlan.fromJson(std.testing.allocator, json);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), plan.expectations.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.failure_signals.items.len);
    try std.testing.expectEqualStrings("test", plan.expectations.items[0].pattern);
    try std.testing.expectEqualStrings("error", plan.failure_signals.items[0].pattern);
    try std.testing.expect(plan.expectations.items[0].must_match);
    try std.testing.expect(plan.failure_signals.items[0].exit_on_match);
}

test "command planner - build command string" {
    const testing = std.testing;

    var runtime = try terminal_runtime.TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    var planner = CommandPlanner.init(testing.allocator, &runtime);
    defer planner.deinit();

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");

    const args = [_][]const u8{ "-l", "/tmp" };

    const plan = CommandPlan{
        .plan_id = "test-1",
        .command = "ls",
        .args = &args,
        .env = env,
        .expectations = .{},
        .failure_signals = .{},
    };

    const cmd_str = try planner.buildCommandString(&plan);
    defer testing.allocator.free(cmd_str);

    // Should contain command and args
    try testing.expect(std.mem.indexOf(u8, cmd_str, "ls") != null);
    try testing.expect(std.mem.indexOf(u8, cmd_str, "-l") != null);
    try testing.expect(std.mem.indexOf(u8, cmd_str, "/tmp") != null);
}

test "command planner - execute simple plan" {
    const testing = std.testing;

    var runtime = try terminal_runtime.TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    var planner = CommandPlanner.init(testing.allocator, &runtime);
    defer planner.deinit();

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    var plan = CommandPlan{
        .plan_id = "exec-test-1",
        .command = "echo",
        .args = &[_][]const u8{"test"},
        .env = env,
        .confirm_mode = .auto,
        .expectations = .{},
        .failure_signals = .{},
    };

    const outcome = try planner.executePlan(&plan);

    try testing.expectEqual(PlanOutcome.success, outcome);
    try testing.expectEqual(@as(usize, 1), planner.audits.items.len);
    try testing.expectEqualStrings("exec-test-1", planner.audits.items[0].plan_id);
}

test "command planner - blocked plan" {
    const testing = std.testing;

    var runtime = try terminal_runtime.TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    var planner = CommandPlanner.init(testing.allocator, &runtime);
    defer planner.deinit();

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    var plan = CommandPlan{
        .plan_id = "blocked-test-1",
        .command = "rm",
        .args = &[_][]const u8{ "-rf", "/" },
        .env = env,
        .confirm_mode = .reject,
        .expectations = .{},
        .failure_signals = .{},
    };

    const outcome = try planner.executePlan(&plan);

    try testing.expectEqual(PlanOutcome.blocked, outcome);
    try testing.expectEqual(@as(usize, 1), planner.audits.items.len);
    try testing.expectEqual(PlanOutcome.blocked, planner.audits.items[0].outcome);
}

test "command planner - snapshot comparison with expectations" {
    const testing = std.testing;

    var runtime = try terminal_runtime.TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Feed some content to the terminal
    try runtime.feedBytes("Hello World\n");

    var planner = CommandPlanner.init(testing.allocator, &runtime);
    defer planner.deinit();

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    // Plan with expectation that should be met
    var expectations: std.ArrayList(Expectation) = .{};
    defer expectations.deinit(testing.allocator);
    try expectations.append(testing.allocator, .{ .pattern = "Hello", .must_match = true });

    var plan = CommandPlan{
        .plan_id = "expect-test-1",
        .command = "echo",
        .args = &[_][]const u8{"test"},
        .env = env,
        .confirm_mode = .auto,
        .expectations = expectations,
        .failure_signals = .{},
    };

    const outcome = try planner.executePlan(&plan);

    // Should succeed because "Hello" is in the framebuffer
    try testing.expectEqual(PlanOutcome.success, outcome);
}

test "command planner - snapshot comparison with failure signals" {
    const testing = std.testing;

    var runtime = try terminal_runtime.TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Feed error content to the terminal
    try runtime.feedBytes("ERROR: Something went wrong\n");

    var planner = CommandPlanner.init(testing.allocator, &runtime);
    defer planner.deinit();

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    // Plan with failure signal that should be detected
    var failure_signals: std.ArrayList(FailureSignal) = .{};
    defer failure_signals.deinit(testing.allocator);
    try failure_signals.append(testing.allocator, .{ .pattern = "ERROR", .exit_on_match = true });

    var plan = CommandPlan{
        .plan_id = "failure-test-1",
        .command = "test",
        .args = &[_][]const u8{},
        .env = env,
        .confirm_mode = .auto,
        .expectations = .{},
        .failure_signals = failure_signals,
    };

    const outcome = try planner.executePlan(&plan);

    // Should fail because "ERROR" is detected in the framebuffer (exit_on_match=true -> failed)
    try testing.expectEqual(PlanOutcome.failed, outcome);

    // Check that error message was recorded
    const audit = planner.audits.items[0];
    try testing.expect(audit.error_message != null);
}

test "command planner - unmet expectations" {
    const testing = std.testing;

    var runtime = try terminal_runtime.TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Feed content that doesn't match expectation
    try runtime.feedBytes("Wrong output\n");

    var planner = CommandPlanner.init(testing.allocator, &runtime);
    defer planner.deinit();

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    // Plan with expectation that won't be met
    var expectations: std.ArrayList(Expectation) = .{};
    defer expectations.deinit(testing.allocator);
    try expectations.append(testing.allocator, .{ .pattern = "Expected output", .must_match = true });

    var plan = CommandPlan{
        .plan_id = "unmet-test-1",
        .command = "test",
        .args = &[_][]const u8{},
        .env = env,
        .confirm_mode = .auto,
        .expectations = expectations,
        .failure_signals = .{},
    };

    const outcome = try planner.executePlan(&plan);

    // Should degrade because expectation not met
    try testing.expectEqual(PlanOutcome.degraded, outcome);

    // Check error message mentions unmet expectation
    const audit = planner.audits.items[0];
    try testing.expect(audit.error_message != null);
    try testing.expect(std.mem.indexOf(u8, audit.error_message.?, "Expectation not met") != null);
}

test "fromJson parses timeout_ms" {
    const json =
        \\{"plan_id":"timeout-test","command":"sleep","args":["10"],"timeout_ms":5000}
    ;

    var plan = try CommandPlan.fromJson(std.testing.allocator, json);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, 5000), plan.timeout_ms);
    try std.testing.expectEqualStrings("timeout-test", plan.plan_id);
}

test "fromJson parses null timeout_ms" {
    const json =
        \\{"plan_id":"no-timeout","command":"echo"}
    ;

    var plan = try CommandPlan.fromJson(std.testing.allocator, json);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, null), plan.timeout_ms);
}

test "toJson serializes timeout_ms" {
    const testing = std.testing;

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    const plan = CommandPlan{
        .plan_id = "json-test",
        .command = "test",
        .args = &[_][]const u8{},
        .env = env,
        .expectations = .{},
        .failure_signals = .{},
        .timeout_ms = 3000,
    };

    const json = try plan.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"timeout_ms\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "3000") != null);
}

test "toJson serializes null timeout_ms" {
    const testing = std.testing;

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    const plan = CommandPlan{
        .plan_id = "json-test-null",
        .command = "test",
        .args = &[_][]const u8{},
        .env = env,
        .expectations = .{},
        .failure_signals = .{},
        .timeout_ms = null,
    };

    const json = try plan.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"timeout_ms\":null") != null);
}

test "matchSimpleRegex - literal substring" {
    try std.testing.expect(matchSimpleRegex("hello", "hello world"));
    try std.testing.expect(matchSimpleRegex("world", "hello world"));
    try std.testing.expect(!matchSimpleRegex("foo", "hello world"));
}

test "matchSimpleRegex - start anchor ^" {
    try std.testing.expect(matchSimpleRegex("^hello", "hello world"));
    try std.testing.expect(!matchSimpleRegex("^world", "hello world"));
    try std.testing.expect(matchSimpleRegex("^", "anything"));
}

test "matchSimpleRegex - end anchor $" {
    try std.testing.expect(matchSimpleRegex("world$", "hello world"));
    try std.testing.expect(!matchSimpleRegex("hello$", "hello world"));
    try std.testing.expect(matchSimpleRegex("$", "anything"));
}

test "matchSimpleRegex - both anchors ^$" {
    try std.testing.expect(matchSimpleRegex("^hello world$", "hello world"));
    try std.testing.expect(!matchSimpleRegex("^hello world$", "hello world!"));
    try std.testing.expect(matchSimpleRegex("^$", ""));
}

test "matchSimpleRegex - .* wildcard" {
    try std.testing.expect(matchSimpleRegex("h.*o", "hello"));
    try std.testing.expect(matchSimpleRegex("h.*d", "hello world"));
    try std.testing.expect(matchSimpleRegex("^.*$", "anything"));
    try std.testing.expect(matchSimpleRegex(".*", ""));
    try std.testing.expect(matchSimpleRegex("a.*z", "abcdefghijklmnopqrstuvwxyz"));
}

test "matchSimpleRegex - .+ wildcard" {
    try std.testing.expect(matchSimpleRegex("h.+o", "hello"));
    try std.testing.expect(!matchSimpleRegex("h.+o", "ho")); // .+ requires at least one char
    try std.testing.expect(matchSimpleRegex("a.+z", "abz"));
    try std.testing.expect(!matchSimpleRegex("a.+z", "az"));
}

test "matchSimpleRegex - single dot" {
    try std.testing.expect(matchSimpleRegex("h.llo", "hello"));
    try std.testing.expect(matchSimpleRegex("h.llo", "hallo"));
    try std.testing.expect(!matchSimpleRegex("h.llo", "hllo"));
}

test "matchSimpleRegex - multiline with anchors" {
    const text = "line1\nline2\nline3";
    try std.testing.expect(matchSimpleRegex("^line1", text));
    try std.testing.expect(matchSimpleRegex("line2", text));
    try std.testing.expect(matchSimpleRegex("line3$", text));
}

test "Expectation.matches - literal vs regex" {
    const literal = Expectation{ .pattern = "hello", .must_match = true, .is_regex = false };
    const regex = Expectation{ .pattern = "^hello", .must_match = true, .is_regex = true };

    try std.testing.expect(literal.matches("say hello world"));
    try std.testing.expect(!regex.matches("say hello world")); // ^ anchors to start
    try std.testing.expect(regex.matches("hello world"));
}

test "fromJson parses is_regex field" {
    const json =
        \\{"plan_id":"regex-test","command":"test",
        \\"expectations":[{"pattern":"^ERROR.*$","must_match":true,"is_regex":true}]}
    ;

    var plan = try CommandPlan.fromJson(std.testing.allocator, json);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), plan.expectations.items.len);
    try std.testing.expect(plan.expectations.items[0].is_regex);
    try std.testing.expectEqualStrings("^ERROR.*$", plan.expectations.items[0].pattern);
}

test "toJson serializes is_regex field" {
    const testing = std.testing;

    var env = std.StringHashMap([]const u8).init(testing.allocator);
    defer env.deinit();

    var expectations: std.ArrayList(Expectation) = .{};
    defer expectations.deinit(testing.allocator);
    try expectations.append(testing.allocator, .{ .pattern = "^test$", .must_match = true, .is_regex = true });

    const plan = CommandPlan{
        .plan_id = "json-regex-test",
        .command = "test",
        .args = &[_][]const u8{},
        .env = env,
        .expectations = expectations,
        .failure_signals = .{},
    };

    const json = try plan.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"is_regex\":true") != null);
}
