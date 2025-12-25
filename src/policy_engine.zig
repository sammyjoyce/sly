/// Policy Engine - Security policy for OSC commands and terminal operations
///
/// Phase 4: OSC Bus & Policy Engine
///
/// Provides typed OSC event routing with policy handlers that return
/// allow/confirm/reject verdicts with rationale. Rejected commands never
/// reach user surfaces.
const std = @import("std");
const ghostty = @import("libghostty.zig");

/// Policy verdict for an OSC command or terminal operation
pub const PolicyVerdict = enum {
    /// Operation is allowed and can proceed automatically
    allow,

    /// Operation requires user confirmation before proceeding
    confirm,

    /// Operation is rejected and must not be executed
    reject,
};

/// Detailed policy decision with rationale
pub const PolicyDecision = struct {
    /// The verdict
    verdict: PolicyVerdict,

    /// Human-readable rationale for the decision
    rationale: []const u8,

    /// Optional metadata about the decision
    metadata: ?[]const u8 = null,

    /// Free any owned memory
    pub fn deinit(self: *PolicyDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.rationale);
        if (self.metadata) |m| {
            allocator.free(m);
        }
    }
};

/// Policy configuration for different OSC command types
pub const PolicyConfig = struct {
    /// Allow window title changes
    allow_title_changes: bool = true,

    /// Require confirmation for title changes
    confirm_title_changes: bool = false,

    /// Allow hyperlinks (OSC 8)
    allow_hyperlinks: bool = true,

    /// Require confirmation for hyperlinks
    confirm_hyperlinks: bool = false,

    /// Allow palette changes
    allow_palette_changes: bool = false,

    /// Require confirmation for palette changes
    confirm_palette_changes: bool = true,

    /// Allow OSC 52 (clipboard operations)
    allow_osc52: bool = true,

    /// Require confirmation for OSC 52
    confirm_osc52: bool = true,

    /// Allow OSC 7 (current directory reporting)
    allow_current_directory: bool = true,

    /// Allow OSC 133 (shell integration markers)
    allow_shell_integration: bool = true,

    /// Allow OSC 777 (notifications)
    allow_notifications: bool = false,

    /// Require confirmation for notifications
    confirm_notifications: bool = true,

    /// Default behavior for unknown OSC commands
    default_unknown: PolicyVerdict = .confirm,
};

/// Default (balanced) policy preset
pub const DEFAULT_POLICY = PolicyConfig{};

/// Strict policy preset - requires confirmation for most operations
pub const STRICT_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .confirm_title_changes = true,
    .allow_hyperlinks = true,
    .confirm_hyperlinks = true,
    .allow_palette_changes = false,
    .confirm_palette_changes = false,
    .allow_osc52 = false,
    .confirm_osc52 = false,
    .allow_current_directory = true,
    .allow_shell_integration = true,
    .allow_notifications = false,
    .confirm_notifications = false,
    .default_unknown = .reject,
};

/// Permissive policy preset - allows most operations without confirmation
pub const PERMISSIVE_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .confirm_title_changes = false,
    .allow_hyperlinks = true,
    .confirm_hyperlinks = false,
    .allow_palette_changes = true,
    .confirm_palette_changes = false,
    .allow_osc52 = true,
    .confirm_osc52 = false,
    .allow_current_directory = true,
    .allow_shell_integration = true,
    .allow_notifications = true,
    .confirm_notifications = false,
    .default_unknown = .allow,
};

/// Policy Engine manages security policies for terminal operations
pub const PolicyEngine = struct {
    allocator: std.mem.Allocator,
    config: PolicyConfig,

    /// Statistics for observability
    stats: PolicyStats,

    pub fn init(allocator: std.mem.Allocator, config: PolicyConfig) PolicyEngine {
        return PolicyEngine{
            .allocator = allocator,
            .config = config,
            .stats = PolicyStats{},
        };
    }

    /// Evaluate policy for an OSC command
    pub fn evaluateOsc(self: *PolicyEngine, command_type: ghostty.OscCommandType, payload: ?[]const u8) !PolicyDecision {
        self.stats.total_osc_evaluations += 1;

        const decision = switch (command_type) {
            ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE => blk: {
                if (self.config.confirm_title_changes) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Window title change requires confirmation"),
                        .metadata = if (payload) |p| try std.fmt.allocPrint(
                            self.allocator,
                            "New title: {s}",
                            .{if (p.len > 50) p[0..50] else p},
                        ) else null,
                    };
                } else if (self.config.allow_title_changes) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Window title changes are allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Window title changes are blocked by policy"),
                    };
                }
            },

            ghostty.OSC_COMMAND_HYPERLINK_START, ghostty.OSC_COMMAND_HYPERLINK_END => blk: {
                if (self.config.confirm_hyperlinks) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Hyperlink requires confirmation"),
                        .metadata = if (payload) |p| try std.fmt.allocPrint(
                            self.allocator,
                            "URL: {s}",
                            .{if (p.len > 100) p[0..100] else p},
                        ) else null,
                    };
                } else if (self.config.allow_hyperlinks) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Hyperlinks are allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Hyperlinks are blocked by policy"),
                    };
                }
            },

            ghostty.OSC_COMMAND_COLOR_OPERATION => blk: {
                if (self.config.confirm_palette_changes) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Palette changes require confirmation"),
                    };
                } else if (self.config.allow_palette_changes) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Palette changes are allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Palette changes are blocked by policy"),
                    };
                }
            },

            ghostty.OSC_COMMAND_CLIPBOARD_CONTENTS => blk: {
                if (self.config.confirm_osc52) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Clipboard access requires confirmation"),
                        .metadata = try std.fmt.allocPrint(
                            self.allocator,
                            "Operation: {s}",
                            .{"clipboard"},
                        ),
                    };
                } else if (self.config.allow_osc52) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Clipboard access is allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Clipboard access is blocked by policy"),
                    };
                }
            },

            ghostty.OSC_COMMAND_REPORT_PWD => blk: {
                if (self.config.allow_current_directory) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Current directory reporting is allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Current directory reporting is blocked by policy"),
                    };
                }
            },

            ghostty.OSC_COMMAND_PROMPT_START,
            ghostty.OSC_COMMAND_PROMPT_END,
            ghostty.OSC_COMMAND_END_OF_INPUT,
            ghostty.OSC_COMMAND_END_OF_COMMAND,
            => blk: {
                if (self.config.allow_shell_integration) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Shell integration is allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Shell integration is blocked by policy"),
                    };
                }
            },

            ghostty.OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION => blk: {
                if (self.config.confirm_notifications) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Notifications require confirmation"),
                        .metadata = if (payload) |p| try std.fmt.allocPrint(
                            self.allocator,
                            "Message: {s}",
                            .{if (p.len > 50) p[0..50] else p},
                        ) else null,
                    };
                } else if (self.config.allow_notifications) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Notifications are allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Notifications are blocked by policy"),
                    };
                }
            },

            else => blk: {
                // Unknown OSC command - use default policy
                self.stats.unknown_commands += 1;
                const verdict = self.config.default_unknown;

                switch (verdict) {
                    .allow => self.stats.allows += 1,
                    .confirm => self.stats.confirmations += 1,
                    .reject => self.stats.rejections += 1,
                }

                break :blk PolicyDecision{
                    .verdict = verdict,
                    .rationale = try std.fmt.allocPrint(
                        self.allocator,
                        "Unknown OSC command (type={}): using default policy '{s}'",
                        .{ command_type, @tagName(verdict) },
                    ),
                };
            },
        };

        std.log.debug("OSC policy decision: type={}, verdict={s}, rationale={s}", .{
            command_type,
            @tagName(decision.verdict),
            decision.rationale,
        });

        return decision;
    }

    /// Evaluate policy for paste operations
    pub fn evaluatePaste(self: *PolicyEngine, text: []const u8, is_safe: bool) !PolicyDecision {
        self.stats.total_paste_evaluations += 1;

        if (is_safe) {
            self.stats.allows += 1;
            return PolicyDecision{
                .verdict = .allow,
                .rationale = try std.fmt.allocPrint(
                    self.allocator,
                    "Paste is safe ({} bytes)",
                    .{text.len},
                ),
            };
        } else {
            self.stats.confirmations += 1;
            return PolicyDecision{
                .verdict = .confirm,
                .rationale = try self.allocator.dupe(u8, "Paste contains potentially dangerous content (newlines detected)"),
                .metadata = try std.fmt.allocPrint(
                    self.allocator,
                    "Preview: {s}",
                    .{if (text.len > 50) text[0..50] else text},
                ),
            };
        }
    }

    /// Get current statistics
    pub fn getStats(self: *const PolicyEngine) PolicyStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *PolicyEngine) void {
        self.stats = PolicyStats{};
    }
};

/// Policy engine statistics for observability
pub const PolicyStats = struct {
    /// Total OSC evaluations
    total_osc_evaluations: u64 = 0,

    /// Total paste evaluations
    total_paste_evaluations: u64 = 0,

    /// Number of operations allowed
    allows: u64 = 0,

    /// Number of operations requiring confirmation
    confirmations: u64 = 0,

    /// Number of operations rejected
    rejections: u64 = 0,

    /// Number of unknown commands encountered
    unknown_commands: u64 = 0,

    pub fn format(
        self: PolicyStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print(
            "PolicyStats{{ osc={}, paste={}, allow={}, confirm={}, reject={}, unknown={} }}",
            .{
                self.total_osc_evaluations,
                self.total_paste_evaluations,
                self.allows,
                self.confirmations,
                self.rejections,
                self.unknown_commands,
            },
        );
    }
};

/// Load policy configuration from environment variables
pub fn loadPolicyFromEnv() PolicyConfig {
    var config = PolicyConfig{};

    if (getEnvBool("SLY_POLICY_STRICT")) {
        config = STRICT_POLICY;
    } else if (getEnvBool("SLY_POLICY_PERMISSIVE")) {
        config = PERMISSIVE_POLICY;
    }

    if (getEnvBool("SLY_ALLOW_OSC52")) {
        config.allow_osc52 = true;
        config.confirm_osc52 = false;
    }

    if (getEnvBool("SLY_BLOCK_NOTIFICATIONS")) {
        config.allow_notifications = false;
        config.confirm_notifications = false;
    }

    if (getEnvBool("SLY_ALLOW_PALETTE")) {
        config.allow_palette_changes = true;
        config.confirm_palette_changes = false;
    }

    return config;
}

fn getEnvBool(name: []const u8) bool {
    const val = std.posix.getenv(name) orelse return false;
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes");
}

// Tests
test "policy engine - allow title changes" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_title_changes = true,
        .confirm_title_changes = false,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, "New Title");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.allow, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.allows);
}

test "policy engine - confirm title changes" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_title_changes = true,
        .confirm_title_changes = true,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, "New Title");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.confirmations);
    try testing.expect(decision.metadata != null);
}

test "policy engine - reject title changes" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_title_changes = false,
        .confirm_title_changes = false,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, null);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.reject, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.rejections);
}

test "policy engine - hyperlink confirmation" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_hyperlinks = true,
        .confirm_hyperlinks = true,
    });

    const url = "https://example.com";
    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_HYPERLINK_START, url);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expect(decision.metadata != null);
}

test "policy engine - clipboard read confirmation" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_osc52 = true,
        .confirm_osc52 = true,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CLIPBOARD_CONTENTS, null);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expect(decision.metadata != null);
    try testing.expect(std.mem.indexOf(u8, decision.metadata.?, "clipboard") != null);
}

test "policy engine - clipboard write confirmation" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_osc52 = true,
        .confirm_osc52 = true,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CLIPBOARD_CONTENTS, "test data");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expect(std.mem.indexOf(u8, decision.metadata.?, "clipboard") != null);
}

test "policy engine - allow shell integration" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_shell_integration = true,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_PROMPT_START, "/home/user");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.allow, decision.verdict);
}

test "policy engine - unknown command uses default policy" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .default_unknown = .confirm,
    });

    // Use an invalid command type value to simulate unknown command
    const unknown_cmd: ghostty.OscCommandType = 9999;
    var decision = try engine.evaluateOsc(unknown_cmd, null);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.unknown_commands);
}

test "policy engine - paste safe text" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{});

    var decision = try engine.evaluatePaste("echo hello", true);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.allow, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.total_paste_evaluations);
    try testing.expectEqual(@as(u64, 1), engine.stats.allows);
}

test "policy engine - paste unsafe text" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{});

    var decision = try engine.evaluatePaste("rm -rf /\nreboot", false);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.confirmations);
    try testing.expect(decision.metadata != null);
}

test "policy engine - statistics tracking" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_title_changes = true,
        .confirm_hyperlinks = true,
        .allow_palette_changes = false,
        .confirm_palette_changes = false, // Explicitly reject, don't confirm
    });

    // Allow
    var d1 = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, null);
    defer d1.deinit(testing.allocator);

    // Confirm
    var d2 = try engine.evaluateOsc(ghostty.OSC_COMMAND_HYPERLINK_START, "https://test.com");
    defer d2.deinit(testing.allocator);

    // Reject
    var d3 = try engine.evaluateOsc(ghostty.OSC_COMMAND_COLOR_OPERATION, null);
    defer d3.deinit(testing.allocator);

    const stats = engine.getStats();
    try testing.expectEqual(@as(u64, 3), stats.total_osc_evaluations);
    try testing.expectEqual(@as(u64, 1), stats.allows);
    try testing.expectEqual(@as(u64, 1), stats.confirmations);
    try testing.expectEqual(@as(u64, 1), stats.rejections);
}

test "DEFAULT_POLICY allows safe operations" {
    const policy = DEFAULT_POLICY;
    try std.testing.expect(policy.allow_title_changes);
    try std.testing.expect(policy.allow_shell_integration);
    try std.testing.expect(!policy.confirm_title_changes);
}

test "STRICT_POLICY blocks clipboard" {
    const policy = STRICT_POLICY;
    try std.testing.expect(!policy.allow_osc52);
    try std.testing.expect(policy.default_unknown == .reject);
}

test "PERMISSIVE_POLICY allows most operations" {
    const policy = PERMISSIVE_POLICY;
    try std.testing.expect(policy.allow_notifications);
    try std.testing.expect(!policy.confirm_osc52);
    try std.testing.expect(policy.default_unknown == .allow);
}
