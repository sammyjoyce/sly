/// Command Planner - Phase 5 Implementation
/// Executes declarative plans through TerminalRuntime with validation and audit trails
const std = @import("std");
const terminal_runtime = @import("terminal_runtime.zig");
const policy_engine = @import("policy_engine.zig");
const ghostty = @import("libghostty.zig");

/// Paste policy for command execution
pub const PastePolicy = enum {
    auto, // Execute without confirmation
    needs_confirm, // Require user confirmation
    never, // Never paste, reject
};

/// Confirmation mode for plan execution
pub const ConfirmMode = enum {
    auto, // Execute immediately
    preview, // Show command before execution
    reject, // Block execution
};

/// Expected outcome after plan execution
pub const Expectation = struct {
    /// Expected pattern in framebuffer/output
    pattern: []const u8,
    /// true = must contain, false = must not contain
    must_match: bool = true,
};

/// Failure signal severity
pub const FailureSeverity = enum {
    warning,
    err,
    critical,
};

/// Failure signal patterns to detect errors
pub const FailureSignal = struct {
    /// Pattern in output that indicates failure
    pattern: []const u8,
    /// Exit on match
    exit_on_match: bool = true,
};

/// Declarative command plan schema
pub const CommandPlan = struct {
    /// Plan identifier for audit trail
    plan_id: []const u8,

    /// Command to execute
    command: []const u8,

    /// Command arguments
    args: []const []const u8 = &.{},

    /// Environment variables
    env: std.StringHashMap([]const u8),

    /// Standard input data
    stdin: ?[]const u8 = null,

    /// Paste safety policy
    paste_policy: PastePolicy = .needs_confirm,

    /// Confirmation mode
    confirm_mode: ConfirmMode = .preview,

    /// Expected outcomes
    expectations: std.ArrayList(Expectation),

    /// Failure signal patterns
    failure_signals: std.ArrayList(FailureSignal),

    /// Plan creation timestamp
    created_at: i64 = 0,

    /// Parse from JSON string
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

                        try expectations.append(allocator, .{
                            .pattern = pattern,
                            .must_match = must_match,
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

                        try failure_signals.append(allocator, .{
                            .pattern = pattern,
                            .exit_on_match = exit_on_match,
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
        };
    }

    /// Free allocated memory
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

    /// Serialize CommandPlan to JSON string
    pub fn toJson(self: CommandPlan, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayList(u8){};
        errdefer output.deinit(allocator);

        try output.append(allocator, '{');
        try output.appendSlice(allocator, "\"plan_id\":\"");
        try output.appendSlice(allocator, self.plan_id);
        try output.appendSlice(allocator, "\",\"command\":\"");
        try output.appendSlice(allocator, self.command);
        try output.appendSlice(allocator, "\",\"args\":[");

        // Args array
        for (self.args, 0..) |arg, i| {
            if (i > 0) try output.append(allocator, ',');
            try output.append(allocator, '"');
            try output.appendSlice(allocator, arg);
            try output.append(allocator, '"');
        }
        try output.appendSlice(allocator, "],\"env\":{");

        // Env object
        var env_iter = self.env.iterator();
        var first_env = true;
        while (env_iter.next()) |entry| {
            if (!first_env) try output.append(allocator, ',');
            try output.append(allocator, '"');
            try output.appendSlice(allocator, entry.key_ptr.*);
            try output.appendSlice(allocator, "\":\"");
            try output.appendSlice(allocator, entry.value_ptr.*);
            try output.append(allocator, '"');
            first_env = false;
        }
        try output.appendSlice(allocator, "},\"stdin\":");

        // Stdin
        if (self.stdin) |stdin| {
            try output.append(allocator, '"');
            try output.appendSlice(allocator, stdin);
            try output.append(allocator, '"');
        } else {
            try output.appendSlice(allocator, "null");
        }

        // Policies and modes
        try output.appendSlice(allocator, ",\"paste_policy\":\"");
        try output.appendSlice(allocator, @tagName(self.paste_policy));
        try output.appendSlice(allocator, "\",\"confirm_mode\":\"");
        try output.appendSlice(allocator, @tagName(self.confirm_mode));
        try output.appendSlice(allocator, "\",\"expectations\":[],\"failure_signals\":[],\"created_at\":");

        // Timestamp
        var buf: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&buf, "{d}", .{self.created_at});
        try output.appendSlice(allocator, timestamp_str);
        try output.append(allocator, '}');

        return output.toOwnedSlice(allocator);
    }
};

/// Plan execution outcome
pub const PlanOutcome = enum {
    success, // All expectations met
    degraded, // Partial success
    blocked, // Execution blocked by policy
    failed, // Failure signals detected
};

/// Audit bundle for plan execution
pub const PlanAudit = struct {
    plan_id: []const u8,
    outcome: PlanOutcome,

    /// Hash of keystream sent to PTY
    keystream_hash: u64,

    /// Snapshot before execution
    snapshot_before: ?[]const u8 = null,

    /// Snapshot after execution
    snapshot_after: ?[]const u8 = null,

    /// OSC events recorded during execution
    osc_events: std.ArrayList([]const u8),

    /// Paste verdicts
    paste_verdicts: std.ArrayList([]const u8),

    /// Execution timestamp
    timestamp: i64,

    /// Error message if any
    error_message: ?[]const u8 = null,

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

/// Command Planner - orchestrates plan execution through TerminalRuntime
pub const CommandPlanner = struct {
    allocator: std.mem.Allocator,
    runtime: *terminal_runtime.TerminalRuntime,

    /// Audit trail of executed plans
    audits: std.ArrayList(PlanAudit),

    pub fn init(allocator: std.mem.Allocator, runtime: *terminal_runtime.TerminalRuntime) CommandPlanner {
        return CommandPlanner{
            .allocator = allocator,
            .runtime = runtime,
            .audits = .{},
        };
    }

    pub fn deinit(self: *CommandPlanner) void {
        for (self.audits.items) |*audit| {
            audit.deinit(self.allocator);
        }
        self.audits.deinit(self.allocator);
    }

    /// Execute a declarative plan
    pub fn executePlan(self: *CommandPlanner, plan: *const CommandPlan) !PlanOutcome {
        std.log.info("Executing plan: {s}", .{plan.plan_id});

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

        // Capture snapshot before execution
        audit.snapshot_before = try self.captureSnapshot(.{});

        // Build command string
        const command_str = try self.buildCommandString(plan);
        defer self.allocator.free(command_str);

        std.log.debug("Command to execute: {s}", .{command_str});

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

    /// Build full command string from plan
    fn buildCommandString(self: *CommandPlanner, plan: *const CommandPlan) ![]const u8 {
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

    /// Compare snapshot against expectations and failure signals
    fn compareSnapshot(
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
        for (failure_signals) |signal| {
            if (try self.matchPattern(signal.pattern, &snapshot)) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Failure signal detected: {s} (exit_on_match: {})",
                    .{ signal.pattern, signal.exit_on_match },
                );
                return ComparisonResult{
                    .outcome = if (signal.exit_on_match) .failed else .degraded,
                    .error_message = msg,
                };
            }
        }

        // Then check expectations
        for (expectations) |expectation| {
            const matched = try self.matchPattern(expectation.pattern, &snapshot);
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

        // Simple substring search (TODO: upgrade to regex when needed)
        return std.mem.indexOf(u8, text, pattern) != null;
    }

    /// Capture current terminal snapshot
    fn captureSnapshot(self: *CommandPlanner, options: terminal_runtime.SnapshotOptions) ![]const u8 {
        // Call TerminalRuntime snapshot method
        var snapshot = try self.runtime.snapshot(options);
        defer snapshot.deinit(self.allocator);

        // Serialize to string for audit trail
        // TODO: Implement proper snapshot serialization once Snapshot has full data
        const snapshot_str = try std.fmt.allocPrint(
            self.allocator,
            "Snapshot(hash={x}, timestamp={}, rows={}, cols={}, cursor={}:{})",
            .{
                snapshot.hash,
                snapshot.timestamp,
                snapshot.rows,
                snapshot.cols,
                snapshot.cursor_row,
                snapshot.cursor_col,
            },
        );
        return snapshot_str;
    }

    /// Get all audits
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
