# Security Policy Specification

## Overview

The security policy system protects users from dangerous terminal operations. It intercepts OSC commands, validates paste operations, and enforces configurable policies that determine what actions are allowed, require confirmation, or are rejected outright.

## Threat Model

### Attack Vectors

| Vector | Description | Mitigation |
|--------|-------------|------------|
| Command injection | Malicious text in paste | Paste validation, bracketed paste |
| OSC escape | Exit bracketed paste early | Escape sequence detection |
| Clipboard hijacking | Read/write clipboard without consent | OSC 52 policy |
| Title spoofing | Misleading window titles | Title change policy |
| Notification spam | Excessive desktop notifications | Notification policy |
| Palette corruption | Unreadable color changes | Palette change policy |

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│                        Untrusted Zone                            │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ PTY Output (from commands, network, files)              │    │
│  │ • Escape sequences                                       │    │
│  │ • OSC commands                                           │    │
│  │ • Paste data                                             │    │
│  └─────────────────────────────────────────────────────────┘    │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                          Policy Engine
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│                         Trusted Zone                             │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ User Display                                             │    │
│  │ • Filtered OSC events                                    │    │
│  │ • Validated paste content                                │    │
│  │ • Policy-approved actions                                │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Policy Engine Architecture

### Core Components

```zig
pub const PolicyEngine = struct {
    allocator: std.mem.Allocator,
    config: PolicyConfig,
    stats: PolicyStats,

    pub fn init(allocator: Allocator, config: PolicyConfig) PolicyEngine;
    pub fn evaluateOsc(self: *PolicyEngine, cmd_type: OscCommandType, payload: ?[]const u8) !PolicyDecision;
    pub fn evaluatePaste(self: *PolicyEngine, text: []const u8, is_safe: bool) !PolicyDecision;
    pub fn getStats(self: *const PolicyEngine) PolicyStats;
    pub fn resetStats(self: *PolicyEngine) void;
};
```

### Policy Verdict

```zig
pub const PolicyVerdict = enum {
    /// Operation allowed, proceed automatically
    allow,

    /// Operation requires user confirmation
    confirm,

    /// Operation rejected, do not execute
    reject,
};
```

### Policy Decision

```zig
pub const PolicyDecision = struct {
    /// The verdict
    verdict: PolicyVerdict,

    /// Human-readable rationale for the decision
    rationale: []const u8,

    /// Optional metadata about the decision
    metadata: ?[]const u8 = null,

    pub fn deinit(self: *PolicyDecision, allocator: Allocator) void;
};
```

## Policy Configuration

### Configuration Structure

```zig
pub const PolicyConfig = struct {
    // Window title operations
    allow_title_changes: bool = true,
    confirm_title_changes: bool = false,

    // Hyperlinks (OSC 8)
    allow_hyperlinks: bool = true,
    confirm_hyperlinks: bool = false,

    // Color palette changes
    allow_palette_changes: bool = false,
    confirm_palette_changes: bool = true,

    // Clipboard operations (OSC 52)
    allow_osc52: bool = true,
    confirm_osc52: bool = true,

    // Current directory reporting (OSC 7)
    allow_current_directory: bool = true,

    // Shell integration markers (OSC 133)
    allow_shell_integration: bool = true,

    // Desktop notifications (OSC 9/777)
    allow_notifications: bool = false,
    confirm_notifications: bool = true,

    // Default for unknown commands
    default_unknown: PolicyVerdict = .confirm,
};
```

### Configuration Presets

#### Default (Balanced)

```zig
const DEFAULT_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .confirm_title_changes = false,
    .allow_hyperlinks = true,
    .confirm_hyperlinks = false,
    .allow_palette_changes = false,
    .confirm_palette_changes = true,
    .allow_osc52 = true,
    .confirm_osc52 = true,
    .allow_shell_integration = true,
    .allow_notifications = false,
    .confirm_notifications = true,
    .default_unknown = .confirm,
};
```

#### Strict

```zig
const STRICT_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .confirm_title_changes = true,
    .allow_hyperlinks = true,
    .confirm_hyperlinks = true,
    .allow_palette_changes = false,
    .confirm_palette_changes = false,  // Reject, not confirm
    .allow_osc52 = false,  // Block clipboard entirely
    .allow_shell_integration = true,
    .allow_notifications = false,
    .default_unknown = .reject,
};
```

#### Permissive

```zig
const PERMISSIVE_POLICY = PolicyConfig{
    .allow_title_changes = true,
    .allow_hyperlinks = true,
    .allow_palette_changes = true,
    .allow_osc52 = true,
    .confirm_osc52 = false,  // Allow clipboard without confirmation
    .allow_notifications = true,
    .default_unknown = .allow,
};
```

## OSC Policy Evaluation

### Evaluation Flow

```
┌─────────────────┐
│   OSC Command   │
│   Received      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Identify Type  │
│  (cmd_type)     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Check Policy   │
│  Configuration  │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌───────┐ ┌───────┐
│Allowed│ │Confirm│
└───────┘ └───┬───┘
              │
              ▼
         ┌────────┐
         │Rejected│
         └────────┘
```

### OSC Type Handling

```zig
pub fn evaluateOsc(self: *PolicyEngine, cmd_type: OscCommandType, payload: ?[]const u8) !PolicyDecision {
    self.stats.total_osc_evaluations += 1;

    return switch (cmd_type) {
        OSC_COMMAND_CHANGE_WINDOW_TITLE => {
            if (self.config.confirm_title_changes) {
                self.stats.confirmations += 1;
                return .{
                    .verdict = .confirm,
                    .rationale = "Window title change requires confirmation",
                    .metadata = formatPayloadPreview(payload, 50),
                };
            } else if (self.config.allow_title_changes) {
                self.stats.allows += 1;
                return .{ .verdict = .allow, .rationale = "Window title changes allowed" };
            } else {
                self.stats.rejections += 1;
                return .{ .verdict = .reject, .rationale = "Window title changes blocked" };
            }
        },

        OSC_COMMAND_CLIPBOARD_CONTENTS => {
            if (self.config.confirm_osc52) {
                self.stats.confirmations += 1;
                return .{
                    .verdict = .confirm,
                    .rationale = "Clipboard access requires confirmation",
                    .metadata = "Operation: clipboard",
                };
            } else if (self.config.allow_osc52) {
                self.stats.allows += 1;
                return .{ .verdict = .allow, .rationale = "Clipboard access allowed" };
            } else {
                self.stats.rejections += 1;
                return .{ .verdict = .reject, .rationale = "Clipboard access blocked" };
            }
        },

        // ... other OSC types

        else => {
            self.stats.unknown_commands += 1;
            return .{
                .verdict = self.config.default_unknown,
                .rationale = "Unknown OSC command: using default policy",
            };
        },
    };
}
```

## Paste Validation

### Safety Checks

libghostty provides `ghostty_paste_is_safe()`:

```zig
/// Check if paste data is safe
/// Returns false if data contains:
/// - Newlines (\n) which can inject commands
/// - Bracketed paste end sequence (\x1b[201~)
pub fn paste_is_safe(data: []const u8) bool {
    return ghostty.paste_is_safe(data.ptr, data.len);
}
```

### Paste Validation Flow

```zig
pub fn enqueuePaste(self: *TerminalRuntime, text: []const u8) !PasteResult {
    // Check libghostty safety
    const is_safe = ghostty.paste_is_safe(text.ptr, text.len);

    // Evaluate policy
    var policy_decision = try self.policy_engine.evaluatePaste(text, is_safe);
    defer policy_decision.deinit(self.allocator);

    // Determine verdict
    const verdict: PasteVerdict = if (is_safe)
        .safe_auto
    else
        .unsafe_needs_confirm;

    // Wrap in bracketed paste
    const wrapped = try wrapBracketedPaste(self.allocator, text);

    return PasteResult{
        .bytes = wrapped,
        .verdict = verdict,
        .rationale = try self.allocator.dupe(u8, policy_decision.rationale),
    };
}
```

### Bracketed Paste

Bracketed paste mode wraps paste data in escape sequences:

```
ESC[200~<paste data>ESC[201~
   ↑                    ↑
   Start marker         End marker
```

This allows the terminal application to distinguish paste from typed input:

```zig
fn wrapBracketedPaste(allocator: Allocator, text: []const u8) ![]const u8 {
    const PASTE_START = "\x1b[200~";
    const PASTE_END = "\x1b[201~";

    const result = try allocator.alloc(u8, PASTE_START.len + text.len + PASTE_END.len);
    @memcpy(result[0..PASTE_START.len], PASTE_START);
    @memcpy(result[PASTE_START.len..][0..text.len], text);
    @memcpy(result[PASTE_START.len + text.len..], PASTE_END);

    return result;
}
```

### Dangerous Paste Patterns

| Pattern | Risk | Example |
|---------|------|---------|
| Newline | Command injection | `rm -rf /\n` |
| Bracketed paste end | Escape paste mode | `\x1b[201~rm -rf /` |
| Control characters | Unexpected behavior | `\x03` (Ctrl+C) |

### Paste Policy Evaluation

```zig
pub fn evaluatePaste(self: *PolicyEngine, text: []const u8, is_safe: bool) !PolicyDecision {
    self.stats.total_paste_evaluations += 1;

    if (is_safe) {
        self.stats.allows += 1;
        return .{
            .verdict = .allow,
            .rationale = try std.fmt.allocPrint(
                self.allocator,
                "Paste is safe ({} bytes)",
                .{text.len},
            ),
        };
    } else {
        self.stats.confirmations += 1;
        return .{
            .verdict = .confirm,
            .rationale = "Paste contains potentially dangerous content",
            .metadata = try formatPayloadPreview(self.allocator, text, 50),
        };
    }
}
```

## Statistics and Observability

### Policy Statistics

```zig
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
};
```

### Logging

```zig
std.log.debug("OSC policy decision: type={}, verdict={s}, rationale={s}", .{
    command_type,
    @tagName(decision.verdict),
    decision.rationale,
});

std.log.info("Terminal runtime shutdown - {any}", .{self.policy_engine.getStats()});
```

### Statistics Output

```
PolicyStats{ osc=42, paste=5, allow=35, confirm=10, reject=2, unknown=0 }
```

## User Confirmation Flow

### Confirmation UI

When a policy requires confirmation:

```
┌─────────────────────────────────────────────────────────────────┐
│ ⚠️  Security Confirmation Required                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│ Action: Clipboard access (OSC 52)                               │
│ Details: Program wants to write to clipboard                    │
│                                                                  │
│ Preview: "rm -rf / # DO NOT RUN THIS..."                        │
│                                                                  │
│ [Allow Once] [Allow Always] [Deny] [Block This Type]           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Confirmation Options

| Option | Behavior |
|--------|----------|
| Allow Once | Permit this specific operation |
| Allow Always | Update policy to allow this type |
| Deny | Block this specific operation |
| Block This Type | Update policy to reject this type |

## Integration with Terminal Runtime

### Event Flow

```zig
fn processOscCommand(self: *TerminalRuntime, command: OscCommand) !void {
    const cmd_type = ghostty.osc_command_type(command);

    // Extract payload
    const payload = extractPayload(command);

    // Evaluate policy
    var decision = try self.policy_engine.evaluateOsc(cmd_type, payload);
    defer decision.deinit(self.allocator);

    // Create event record
    var event = OscEvent{
        .command_type = cmd_type,
        .payload = if (payload) |p| try self.allocator.dupe(u8, p) else null,
        .allowed = decision.verdict == .allow,
        .needs_confirmation = decision.verdict == .confirm,
        .rationale = try self.allocator.dupe(u8, decision.rationale),
    };

    // Store event
    try self.osc_events.append(self.allocator, event);

    // Execute if allowed
    if (decision.verdict == .allow) {
        try self.executeOscCommand(cmd_type, payload);
    }
}
```

### Snapshot Integration

OSC events in snapshots include policy decisions:

```zig
pub const OscEvent = struct {
    command_type: OscCommandType,
    payload: ?[]u8 = null,
    allowed: bool = true,
    needs_confirmation: bool = false,
    rationale: ?[]u8 = null,
};
```

## Command Plan Security

### Plan Policies

```zig
pub const PastePolicy = enum {
    auto,          // Execute without confirmation
    needs_confirm, // Require user confirmation
    never,         // Never paste, reject
};

pub const ConfirmMode = enum {
    auto,    // Execute immediately
    preview, // Show command before execution
    reject,  // Block execution
};
```

### Dangerous Command Detection

LLM-generated commands are evaluated:

```zig
// In system prompt
\\6. paste_policy: "auto" for safe commands, "needs_confirm" for potentially dangerous ones
\\7. confirm_mode: "auto" for safe execution, "preview" to show before running

// Examples of dangerous commands
\\User: "delete all logs"
\\{"paste_policy":"needs_confirm","confirm_mode":"preview",...}
```

## Environment Variable Override

### Runtime Configuration

```bash
# Strict mode
export SLY_POLICY_STRICT=1

# Allow clipboard without confirmation
export SLY_ALLOW_OSC52=1

# Block all notifications
export SLY_BLOCK_NOTIFICATIONS=1
```

### Configuration Loading

```zig
pub fn loadPolicyFromEnv(allocator: Allocator) !PolicyConfig {
    var config = PolicyConfig{};

    if (getEnvBool("SLY_POLICY_STRICT")) {
        config = STRICT_POLICY;
    }

    if (getEnvBool("SLY_ALLOW_OSC52")) {
        config.allow_osc52 = true;
        config.confirm_osc52 = false;
    }

    if (getEnvBool("SLY_BLOCK_NOTIFICATIONS")) {
        config.allow_notifications = false;
        config.confirm_notifications = false;
    }

    return config;
}
```

## Security Best Practices

### For Users

1. **Review confirmations**: Don't blindly accept security prompts
2. **Use strict mode**: For untrusted remote sessions
3. **Monitor statistics**: Check policy stats periodically
4. **Report anomalies**: Unexpected OSC commands may indicate attacks

### For Developers

1. **Default deny**: Err on the side of caution for unknown commands
2. **Audit logging**: Log all policy decisions
3. **Payload limits**: Truncate large payloads in metadata
4. **No secrets in rationale**: Don't include sensitive data in logs
