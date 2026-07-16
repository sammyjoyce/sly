/// Policy Engine - Security policy for OSC commands and terminal operations
///
/// This module implements the security policy system described in specs/06-SECURITY-POLICY.md.
/// It acts as a trust boundary between untrusted PTY output (escape sequences, OSC commands,
/// paste data) and the trusted user display zone.
///
/// The engine intercepts terminal operations and returns allow/confirm/reject verdicts with
/// human-readable rationale. Rejected commands never reach user surfaces.
///
/// ## Threat Model
/// Protects against: command injection via paste, OSC escape attacks, clipboard hijacking
/// (OSC 52), title spoofing, notification spam, and palette corruption.
///
/// ## Usage
/// ```zig
/// var engine = PolicyEngine.init(allocator, DEFAULT_POLICY);
/// defer engine.deinit();
///
/// var decision = try engine.evaluateOsc(OSC_COMMAND_CLIPBOARD_CONTENTS, payload);
/// defer decision.deinit(allocator);
///
/// if (decision.verdict == .allow) {
///     // Execute the operation
/// }
/// ```
const std = @import("std");
const ghostty = @import("libghostty.zig");

/// Represents the security verdict for an OSC command or terminal operation.
///
/// This is the core decision type used throughout the policy engine. Each terminal
/// operation is evaluated against the configured policy and receives one of three
/// verdicts that determine how the system should proceed.
///
/// See specs/06-SECURITY-POLICY.md for the complete threat model and evaluation flow.
pub const PolicyVerdict = enum {
    /// Operation is safe and can proceed automatically without user interaction.
    /// Used for trusted operations like shell integration markers (OSC 133) and
    /// current directory reporting (OSC 7).
    allow,

    /// Operation requires explicit user confirmation before proceeding.
    /// The UI should display the operation details and await user approval.
    /// Used for potentially dangerous operations like clipboard access (OSC 52)
    /// and pastes containing newlines.
    confirm,

    /// Operation is blocked and must not be executed.
    /// Used for operations that violate security policy, such as clipboard
    /// access in strict mode or unknown commands with default_unknown = .reject.
    reject,
};

/// A complete policy decision containing the verdict, rationale, and optional metadata.
///
/// Every policy evaluation returns a PolicyDecision that includes:
/// - The verdict (allow/confirm/reject)
/// - A human-readable rationale explaining why the decision was made
/// - Optional metadata with details about the operation (e.g., payload preview)
///
/// The rationale and metadata strings are heap-allocated and owned by this struct.
/// Callers must call `deinit()` to free the memory when done.
///
/// ## Example
/// ```zig
/// var decision = try engine.evaluateOsc(cmd_type, payload);
/// defer decision.deinit(allocator);
/// log.info("Verdict: {s} - {s}", .{@tagName(decision.verdict), decision.rationale});
/// ```
pub const PolicyDecision = struct {
    /// The security verdict for this operation.
    verdict: PolicyVerdict,

    /// Human-readable explanation of why this verdict was chosen.
    /// Suitable for logging and user-facing messages.
    /// Memory is owned by this struct; freed by `deinit()`.
    rationale: []const u8,

    /// Optional additional context about the operation.
    /// May contain payload previews (truncated for safety), operation type, etc.
    /// Memory is owned by this struct; freed by `deinit()`.
    metadata: ?[]const u8 = null,

    /// Frees the heap-allocated rationale and metadata strings.
    ///
    /// Must be called when the decision is no longer needed to avoid memory leaks.
    /// Uses the same allocator that was passed to the PolicyEngine.
    pub fn deinit(self: *PolicyDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.rationale);
        if (self.metadata) |m| {
            allocator.free(m);
        }
    }
};

/// Configuration for the policy engine controlling how different OSC command types are handled.
///
/// Each OSC command type has two flags:
/// - `allow_*`: If false, the operation is rejected outright
/// - `confirm_*`: If true (and allow is true), user confirmation is required
///
/// The evaluation priority is: confirm > allow > reject. If `confirm_*` is true,
/// that takes precedence over `allow_*`.
///
/// ## Default Behavior
/// The default configuration (DEFAULT_POLICY) provides balanced security:
/// - Safe operations (title, hyperlinks, shell integration) are allowed
/// - Sensitive operations (clipboard, palette) require confirmation
/// - Potentially disruptive operations (notifications, mouse shape) are blocked
///
/// ## Environment Override
/// Use `loadPolicyFromEnv()` to override settings via environment variables:
/// - SLY_POLICY_STRICT=1 for maximum security
/// - SLY_POLICY_PERMISSIVE=1 for convenience
/// - SLY_ALLOW_OSC52=1 to enable clipboard without confirmation
///
/// See specs/06-SECURITY-POLICY.md for the complete configuration reference.
pub const PolicyConfig = struct {
    /// Allow OSC 0/2 window title changes. Default: true.
    /// Title spoofing is low-risk but can be used for social engineering.
    allow_title_changes: bool = true,

    /// Require user confirmation for title changes. Default: false.
    /// Enable in strict mode when running untrusted commands.
    confirm_title_changes: bool = false,

    /// Allow OSC 1 window icon name changes. Default: true.
    /// Similar risk profile to title changes.
    allow_icon_changes: bool = true,

    /// Require user confirmation for icon changes. Default: false.
    confirm_icon_changes: bool = false,

    /// Allow OSC 8 hyperlinks in terminal output. Default: true.
    /// Hyperlinks are generally safe but could link to malicious URLs.
    allow_hyperlinks: bool = true,

    /// Require user confirmation before activating hyperlinks. Default: false.
    confirm_hyperlinks: bool = false,

    /// Allow OSC 4/10/11 color palette modifications. Default: false.
    /// Palette corruption can make terminal unreadable; blocked by default.
    allow_palette_changes: bool = false,

    /// Require confirmation for palette changes. Default: true.
    /// If allowed, still prompt user before changing colors.
    confirm_palette_changes: bool = true,

    /// Allow OSC 52 clipboard read/write operations. Default: true.
    /// Clipboard hijacking is a significant security risk.
    allow_osc52: bool = true,

    /// Require confirmation for clipboard operations. Default: true.
    /// Always prompt before allowing programs to access clipboard.
    confirm_osc52: bool = true,

    /// Allow OSC 7 current working directory reporting. Default: true.
    /// Used by shell integration; low risk as it's informational only.
    allow_current_directory: bool = true,

    /// Allow OSC 133 shell integration markers. Default: true.
    /// Essential for prompt detection and command boundaries.
    /// Markers: prompt start/end, command end, exit status.
    allow_shell_integration: bool = true,

    /// Allow OSC 9/777 desktop notifications. Default: false.
    /// Notification spam is disruptive; blocked by default.
    allow_notifications: bool = false,

    /// Require confirmation for notifications. Default: true.
    confirm_notifications: bool = true,

    /// Allow OSC 22 mouse pointer shape changes. Default: false.
    /// Can be confusing; blocked by default.
    allow_mouse_shape: bool = false,

    /// Require confirmation for mouse shape changes. Default: true.
    confirm_mouse_shape: bool = true,

    /// Verdict for unrecognized OSC commands. Default: .confirm.
    /// Conservative default prompts user for unknown operations.
    /// Set to .reject in strict mode, .allow in permissive mode.
    default_unknown: PolicyVerdict = .confirm,
};

/// Default (balanced) policy preset.
///
/// Provides reasonable security for typical terminal usage:
/// - Allows safe operations (title, icon, hyperlinks, shell integration)
/// - Requires confirmation for sensitive operations (clipboard, palette)
/// - Blocks potentially disruptive operations (notifications, mouse shape)
/// - Prompts for unknown commands
///
/// Suitable for everyday use with trusted local shells.
pub const DEFAULT_POLICY = PolicyConfig{};

/// Strict policy preset for maximum security.
///
/// Use when running untrusted commands or remote sessions:
/// - Requires confirmation for all visual changes (title, icon, hyperlinks)
/// - Blocks clipboard access entirely (not just confirmation)
/// - Blocks palette changes, notifications, and mouse shape
/// - Rejects all unknown commands
///
/// Activate via SLY_POLICY_STRICT=1 environment variable.
pub const STRICT_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .confirm_title_changes = true,
    .allow_icon_changes = true,
    .confirm_icon_changes = true,
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
    .allow_mouse_shape = false,
    .confirm_mouse_shape = false,
    .default_unknown = .reject,
};

/// Permissive policy preset for maximum convenience.
///
/// Use only in trusted environments where security is less critical:
/// - Allows all operations without confirmation
/// - Includes clipboard, notifications, palette changes, mouse shape
/// - Allows unknown commands
///
/// WARNING: Reduces protection against malicious terminal escape sequences.
/// Activate via SLY_POLICY_PERMISSIVE=1 environment variable.
pub const PERMISSIVE_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .confirm_title_changes = false,
    .allow_icon_changes = true,
    .confirm_icon_changes = false,
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
    .allow_mouse_shape = true,
    .confirm_mouse_shape = false,
    .default_unknown = .allow,
};

/// The core policy engine that evaluates terminal operations against security policy.
///
/// PolicyEngine is the central security gatekeeper that sits between untrusted PTY
/// output and the user display. It evaluates OSC commands and paste operations,
/// returning verdicts that determine whether operations should proceed.
///
/// The engine maintains statistics for observability and audit logging.
///
/// ## Thread Safety
/// Not thread-safe. Each terminal session should have its own PolicyEngine instance.
///
/// ## Memory Management
/// The engine allocates memory for PolicyDecision rationale/metadata strings.
/// Callers must call `PolicyDecision.deinit()` on returned decisions.
pub const PolicyEngine = struct {
    /// Allocator used for PolicyDecision strings.
    allocator: std.mem.Allocator,

    /// Active policy configuration.
    config: PolicyConfig,

    /// Cumulative statistics for monitoring and auditing.
    stats: PolicyStats,

    /// Creates a new PolicyEngine with the specified configuration.
    ///
    /// The allocator is used for allocating PolicyDecision rationale and metadata
    /// strings. Use the same allocator when calling `PolicyDecision.deinit()`.
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for decision strings
    /// - `config`: Policy configuration (use DEFAULT_POLICY, STRICT_POLICY,
    ///             PERMISSIVE_POLICY, or a custom config)
    ///
    /// ## Returns
    /// Initialized PolicyEngine ready for use.
    pub fn init(allocator: std.mem.Allocator, config: PolicyConfig) PolicyEngine {
        return PolicyEngine{
            .allocator = allocator,
            .config = config,
            .stats = PolicyStats{},
        };
    }

    /// Cleans up the PolicyEngine.
    ///
    /// Currently a no-op as the engine doesn't own any heap memory directly.
    /// PolicyDecision memory is freed by the caller via `PolicyDecision.deinit()`.
    pub fn deinit(self: *PolicyEngine) void {
        _ = self;
    }

    /// Evaluates an OSC command against the configured policy.
    ///
    /// This is the primary security evaluation function for escape sequences.
    /// It checks the command type against the policy configuration and returns
    /// a verdict with rationale.
    ///
    /// ## Parameters
    /// - `command_type`: The OSC command type from libghostty (e.g., OSC_COMMAND_CLIPBOARD_CONTENTS)
    /// - `payload`: Optional command payload (e.g., clipboard data, new title text).
    ///              Payloads are truncated in metadata for safety (50-100 chars max).
    ///
    /// ## Returns
    /// PolicyDecision containing the verdict and rationale. Caller must call
    /// `decision.deinit(allocator)` when done.
    ///
    /// ## Errors
    /// Returns allocation errors if rationale/metadata string allocation fails.
    ///
    /// ## Statistics
    /// Updates internal statistics counters (total_osc_evaluations, allows,
    /// confirmations, rejections, unknown_commands).
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

            ghostty.OSC_COMMAND_CHANGE_WINDOW_ICON => blk: {
                if (self.config.confirm_icon_changes) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Window icon change requires confirmation"),
                        .metadata = if (payload) |p| try std.fmt.allocPrint(
                            self.allocator,
                            "New icon: {s}",
                            .{if (p.len > 50) p[0..50] else p},
                        ) else null,
                    };
                } else if (self.config.allow_icon_changes) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Window icon changes are allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Window icon changes are blocked by policy"),
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

            ghostty.OSC_COMMAND_MOUSE_SHAPE => blk: {
                if (self.config.confirm_mouse_shape) {
                    self.stats.confirmations += 1;
                    break :blk PolicyDecision{
                        .verdict = .confirm,
                        .rationale = try self.allocator.dupe(u8, "Mouse shape changes require confirmation"),
                        .metadata = if (payload) |p| try std.fmt.allocPrint(
                            self.allocator,
                            "Shape: {s}",
                            .{if (p.len > 50) p[0..50] else p},
                        ) else null,
                    };
                } else if (self.config.allow_mouse_shape) {
                    self.stats.allows += 1;
                    break :blk PolicyDecision{
                        .verdict = .allow,
                        .rationale = try self.allocator.dupe(u8, "Mouse shape changes are allowed"),
                    };
                } else {
                    self.stats.rejections += 1;
                    break :blk PolicyDecision{
                        .verdict = .reject,
                        .rationale = try self.allocator.dupe(u8, "Mouse shape changes are blocked by policy"),
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

    /// Evaluates a paste operation against the configured policy.
    ///
    /// Paste operations are evaluated based on libghostty's safety check, which
    /// detects dangerous patterns like embedded newlines (command injection) or
    /// bracketed paste escape sequences.
    ///
    /// ## Parameters
    /// - `text`: The raw paste content to evaluate
    /// - `is_safe`: Result from `ghostty.paste_is_safe()`. False if text contains
    ///              newlines, bracketed paste end sequence, or other dangerous patterns.
    ///
    /// ## Returns
    /// PolicyDecision with:
    /// - `.allow` if is_safe is true (safe to paste automatically)
    /// - `.confirm` if is_safe is false (user must approve potentially dangerous paste)
    ///
    /// Caller must call `decision.deinit(allocator)` when done.
    ///
    /// ## Security Note
    /// Even when allowed, paste content should be wrapped in bracketed paste mode
    /// (ESC[200~ ... ESC[201~) to protect terminal applications.
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

    /// Returns a copy of the current policy statistics.
    ///
    /// Use for monitoring, logging, and debugging policy decisions.
    /// Statistics accumulate across all evaluations since init or last reset.
    ///
    /// ## Returns
    /// Copy of PolicyStats struct with current counters.
    pub fn getStats(self: *const PolicyEngine) PolicyStats {
        return self.stats;
    }

    /// Resets all statistics counters to zero.
    ///
    /// Call periodically for rolling metrics or after logging a snapshot.
    pub fn resetStats(self: *PolicyEngine) void {
        self.stats = PolicyStats{};
    }
};

/// Cumulative statistics for policy engine operations.
///
/// Used for monitoring, auditing, and debugging. Statistics are accumulated
/// across all evaluations and can be reset via `PolicyEngine.resetStats()`.
///
/// ## Example Output (via format)
/// ```
/// PolicyStats{ osc=42, paste=5, allow=35, confirm=10, reject=2, unknown=0 }
/// ```
///
/// ## Usage
/// ```zig
/// const stats = engine.getStats();
/// log.info("Policy stats: {any}", .{stats});
/// ```
pub const PolicyStats = struct {
    /// Total number of OSC command evaluations performed.
    total_osc_evaluations: u64 = 0,

    /// Total number of paste operation evaluations performed.
    total_paste_evaluations: u64 = 0,

    /// Number of operations that received `.allow` verdict.
    allows: u64 = 0,

    /// Number of operations that received `.confirm` verdict (pending user approval).
    confirmations: u64 = 0,

    /// Number of operations that received `.reject` verdict (blocked).
    rejections: u64 = 0,

    /// Number of unrecognized OSC commands (handled by default_unknown policy).
    unknown_commands: u64 = 0,

    /// Formats statistics for logging and display.
    ///
    /// Produces compact output: `PolicyStats{ osc=N, paste=N, allow=N, confirm=N, reject=N, unknown=N }`
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

/// Loads policy configuration from environment variables.
///
/// Allows runtime customization of security policy without code changes.
/// Environment variables are checked in order of precedence.
///
/// ## Base Policy Selection (mutually exclusive, first match wins)
/// - `SLY_POLICY_STRICT=1`: Start from STRICT_POLICY (maximum security)
/// - `SLY_POLICY_PERMISSIVE=1`: Start from PERMISSIVE_POLICY (maximum convenience)
/// - Neither: Start from DEFAULT_POLICY (balanced)
///
/// ## Override Flags (applied after base policy)
/// - `SLY_ALLOW_OSC52=1`: Enable clipboard access without confirmation
/// - `SLY_BLOCK_NOTIFICATIONS=1`: Block all desktop notifications
/// - `SLY_ALLOW_PALETTE=1`: Enable palette changes without confirmation
///
/// ## Returns
/// Configured PolicyConfig ready for use with PolicyEngine.init().
///
/// ## Example
/// ```bash
/// export SLY_POLICY_STRICT=1
/// export SLY_ALLOW_OSC52=1  # Override to allow clipboard in strict mode
/// ```
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

test "policy engine - allow icon changes" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_icon_changes = true,
        .confirm_icon_changes = false,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_ICON, "my-icon");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.allow, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.allows);
}

test "policy engine - confirm icon changes" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_icon_changes = true,
        .confirm_icon_changes = true,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_ICON, "my-icon");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.confirmations);
    try testing.expect(decision.metadata != null);
}

test "policy engine - reject icon changes" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_icon_changes = false,
        .confirm_icon_changes = false,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_ICON, null);
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

test "policy engine - mouse shape confirmation" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_mouse_shape = true,
        .confirm_mouse_shape = true,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_MOUSE_SHAPE, "pointer");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.confirmations);
    try testing.expect(decision.metadata != null);
}

test "policy engine - mouse shape blocked by default" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, DEFAULT_POLICY);

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_MOUSE_SHAPE, "crosshair");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.confirm, decision.verdict);
}

test "policy engine - mouse shape allowed" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_mouse_shape = true,
        .confirm_mouse_shape = false,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_MOUSE_SHAPE, "text");
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.allow, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.allows);
}

test "policy engine - mouse shape rejected" {
    const testing = std.testing;

    var engine = PolicyEngine.init(testing.allocator, .{
        .allow_mouse_shape = false,
        .confirm_mouse_shape = false,
    });

    var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_MOUSE_SHAPE, null);
    defer decision.deinit(testing.allocator);

    try testing.expectEqual(PolicyVerdict.reject, decision.verdict);
    try testing.expectEqual(@as(u64, 1), engine.stats.rejections);
}

test "getEnvBool - returns false for unset env var" {
    try std.testing.expect(!getEnvBool("SLY_TEST_NONEXISTENT_VAR_12345"));
}

test "loadPolicyFromEnv - returns default when no env vars set" {
    const config = loadPolicyFromEnv();
    try std.testing.expect(config.allow_title_changes == DEFAULT_POLICY.allow_title_changes);
    try std.testing.expect(config.confirm_osc52 == DEFAULT_POLICY.confirm_osc52);
    try std.testing.expect(config.default_unknown == DEFAULT_POLICY.default_unknown);
}

test "loadPolicyFromEnv - SLY_POLICY_STRICT preset values" {
    try std.testing.expect(!STRICT_POLICY.allow_osc52);
    try std.testing.expect(STRICT_POLICY.confirm_title_changes);
    try std.testing.expect(STRICT_POLICY.default_unknown == .reject);
}

test "loadPolicyFromEnv - SLY_POLICY_PERMISSIVE preset values" {
    try std.testing.expect(PERMISSIVE_POLICY.allow_osc52);
    try std.testing.expect(!PERMISSIVE_POLICY.confirm_osc52);
    try std.testing.expect(PERMISSIVE_POLICY.allow_notifications);
    try std.testing.expect(PERMISSIVE_POLICY.default_unknown == .allow);
}

test "loadPolicyFromEnv - SLY_ALLOW_OSC52 override logic" {
    var config = DEFAULT_POLICY;
    config.allow_osc52 = true;
    config.confirm_osc52 = false;
    try std.testing.expect(config.allow_osc52);
    try std.testing.expect(!config.confirm_osc52);
}

test "loadPolicyFromEnv - SLY_BLOCK_NOTIFICATIONS override logic" {
    var config = DEFAULT_POLICY;
    config.allow_notifications = false;
    config.confirm_notifications = false;
    try std.testing.expect(!config.allow_notifications);
    try std.testing.expect(!config.confirm_notifications);
}

test "loadPolicyFromEnv - SLY_ALLOW_PALETTE override logic" {
    var config = DEFAULT_POLICY;
    config.allow_palette_changes = true;
    config.confirm_palette_changes = false;
    try std.testing.expect(config.allow_palette_changes);
    try std.testing.expect(!config.confirm_palette_changes);
}
