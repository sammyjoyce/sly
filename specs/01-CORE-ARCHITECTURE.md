# Core Architecture

## Overview

The core architecture of sly is built around the **Terminal Runtime**—a high-level abstraction over libghostty-vt that manages terminal state, key encoding, OSC/SGR parsing, and policy enforcement. This document specifies the component design and their interactions.

## Component Diagram

```
                                  ┌─────────────────────────┐
                                  │     Shell Plugin        │
                                  │   (zsh/bash widget)     │
                                  └───────────┬─────────────┘
                                              │ invoke sly CLI
                                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              sly CLI                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐ │
│  │   Argzon    │  │  Commands   │  │   Config    │  │   Help/Version  │ │
│  │   Parser    │  │  Dispatch   │  │   Loader    │  │   Output        │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────┘ │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         Command Planner                                  │
│  ┌─────────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │   Plan Generation   │  │  Plan Validation │  │   Plan Execution   │  │
│  │  (LLM → CommandPlan)│  │  (Schema check)  │  │  (Key injection)   │  │
│  └─────────────────────┘  └─────────────────┘  └─────────────────────┘  │
│  ┌─────────────────────┐  ┌─────────────────┐                           │
│  │   Audit Trail       │  │  Expectations   │                           │
│  │  (Hash, snapshots)  │  │  (Pattern match)│                           │
│  └─────────────────────┘  └─────────────────┘                           │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Terminal Runtime                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐   │
│  │   Key Encoder    │  │   SGR Parser     │  │    OSC Parser        │   │
│  │  (Kitty protocol)│  │  (Styling attrs) │  │  (Titles, clipboard) │   │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐   │
│  │   Framebuffer    │  │   Cursor State   │  │   Snapshot Engine    │   │
│  │  (Cell grid)     │  │  (Position, mode)│  │  (Hash, serialize)   │   │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                      Policy Engine                                │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐               │   │
│  │  │ OSC Policy  │  │ Paste Policy│  │ Statistics  │               │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          libghostty-vt                                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │ Key Encoder API │  │  SGR Parser API │  │    OSC Parser API       │  │
│  │ ghostty_key_*   │  │  ghostty_sgr_*  │  │    ghostty_osc_*        │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │ Paste Utils API │  │  Memory Mgmt    │  │    Result Codes         │  │
│  │ ghostty_paste_* │  │  GhosttyAllocator│  │    GHOSTTY_SUCCESS, etc│  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

## Terminal Runtime

The Terminal Runtime is the central component that bridges sly with libghostty-vt.

### Responsibilities

1. **Lifecycle Management**: Initialize and shutdown libghostty components
2. **Key Encoding**: Convert key events to terminal escape sequences
3. **VT Parsing**: Process terminal output (SGR, OSC, control sequences)
4. **State Management**: Maintain framebuffer, cursor position, styling
5. **Snapshot Creation**: Capture immutable terminal state for LLM context
6. **Policy Enforcement**: Apply security policies to OSC commands and pastes

### Initialization Parameters

```zig
pub const InitParams = struct {
    /// Terminal dimensions
    cols: u16 = 80,
    rows: u16 = 24,

    /// Scrollback configuration
    scrollback_depth: u32 = 10000,

    /// Custom allocator (null = default)
    allocator: ?*const GhosttyAllocator = null,

    /// Kitty keyboard protocol settings
    enable_kitty_keyboard: bool = true,
    kitty_flags: KittyKeyFlags = KITTY_KEY_ALL,

    /// Security policy configuration
    policy_config: PolicyConfig = .{},
};
```

### Key Methods

| Method | Description |
|--------|-------------|
| `init(allocator, params)` | Create runtime with configuration |
| `shutdown()` | Free all resources |
| `reset()` | Reset terminal to initial state |
| `resize(cols, rows)` | Handle terminal resize |
| `feedBytes(bytes)` | Process PTY output |
| `injectKey(action, key, mods)` | Encode and return key sequence |
| `enqueuePaste(text)` | Validate and encode paste with bracketed paste |
| `snapshot(options)` | Capture immutable terminal state |
| `setKeyEncoderOptions(options)` | Configure key encoder at runtime |

## Framebuffer Model

The framebuffer represents the visible terminal screen as a 2D grid of cells.

### Cell Structure

```zig
pub const Cell = struct {
    /// Character at this position (UTF-8 codepoint, simplified to u8)
    char: u8 = ' ',

    /// Foreground color (palette index or null for default)
    fg_color: ?u8 = null,

    /// Background color (palette index or null for default)
    bg_color: ?u8 = null,

    /// Text attributes
    bold: bool = false,
    italic: bool = false,
    underline: SgrUnderline = SGR_UNDERLINE_NONE,
};
```

### Framebuffer Operations

- **Write**: Characters are written at cursor position, advancing cursor
- **Newline**: Moves cursor to start of next line, scrolling if needed
- **Scroll**: When cursor exceeds viewport, scroll content up
- **Clear**: Reset cells to default state
- **Resize**: Reflow content when dimensions change

## Snapshot System

Snapshots capture terminal state for LLM context and audit trails.

### Snapshot Structure

```zig
pub const Snapshot = struct {
    /// Content hash for change detection
    hash: u64,

    /// Capture timestamp
    timestamp: i64,

    /// Terminal dimensions
    rows: u16,
    cols: u16,

    /// Deep copy of framebuffer
    framebuffer: []const []const Cell,

    /// Cursor position
    cursor_row: u16,
    cursor_col: u16,

    /// Recent OSC events with policy decisions
    osc_events: []const OscEvent,
};
```

### Snapshot Options

```zig
pub const SnapshotOptions = struct {
    /// Include scrollback buffer
    include_scrollback: bool = true,

    /// Maximum scrollback lines to include
    scrollback_lines: u32 = 100,
};
```

### Hash Computation

The snapshot hash enables efficient change detection:

```zig
fn computeHash(framebuffer, cursor_row, cursor_col) u64 {
    var hasher = std.hash.Wyhash.init(0);
    
    for (framebuffer) |row| {
        for (row) |cell| {
            hasher.update(&[_]u8{cell.char});
            if (cell.fg_color) |c| hasher.update(&[_]u8{c});
            if (cell.bg_color) |c| hasher.update(&[_]u8{c});
            hasher.update(&[_]u8{@intFromBool(cell.bold)});
            hasher.update(&[_]u8{@intFromBool(cell.italic)});
            hasher.update(&[_]u8{@truncate(cell.underline)});
        }
    }
    
    hasher.update(std.mem.asBytes(&cursor_row));
    hasher.update(std.mem.asBytes(&cursor_col));
    
    return hasher.final();
}
```

## VT Parsing State Machine

The terminal runtime parses VT100/VT220 escape sequences:

### Parse States

```
┌─────────┐   ESC   ┌─────────┐   [   ┌─────────┐
│ NORMAL  │ ──────► │ ESCAPE  │ ────► │   CSI   │
└────┬────┘         └────┬────┘       └────┬────┘
     │                   │ ]               │ m
     │ printable    ┌────▼────┐       ┌────▼────┐
     │              │   OSC   │       │   SGR   │
     └──────────────┴─────────┘       └─────────┘
```

### Sequence Types

| Sequence | Example | Purpose |
|----------|---------|---------|
| CSI SGR | `ESC[1;31m` | Set text attributes (bold, red) |
| CSI Cursor | `ESC[H` | Move cursor to home |
| OSC Title | `ESC]2;Title\x07` | Set window title |
| OSC PWD | `ESC]7;file://...\x07` | Report current directory |
| OSC 133 | `ESC]133;A\x07` | Shell integration markers |

## Command Planner

The Command Planner orchestrates plan generation and execution.

### CommandPlan Schema

```zig
pub const CommandPlan = struct {
    /// Unique identifier for audit trail
    plan_id: []const u8,

    /// Base command (e.g., "git", "find")
    command: []const u8,

    /// Command arguments
    args: []const []const u8,

    /// Environment variables
    env: StringHashMap([]const u8),

    /// Standard input data
    stdin: ?[]const u8,

    /// Paste safety policy
    paste_policy: enum { auto, needs_confirm, never },

    /// Confirmation mode
    confirm_mode: enum { auto, preview, reject },

    /// Expected outcomes for validation
    expectations: []const Expectation,

    /// Error patterns to detect
    failure_signals: []const FailureSignal,

    /// Creation timestamp
    created_at: i64,
};
```

### Plan Execution Flow

```
┌───────────────┐
│ Generate Plan │  LLM Provider
└───────┬───────┘
        │ CommandPlan JSON
        ▼
┌───────────────┐
│ Validate Plan │  Schema + Policy
└───────┬───────┘
        │ Valid plan
        ▼
┌───────────────┐
│ Capture Before│  Snapshot
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Inject Keys   │  Key Encoder
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Capture After │  Snapshot
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Validate Out  │  Expectations
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Audit Record  │  Hash + Snapshots
└───────────────┘
```

## Memory Management

### Ownership Rules

1. **Allocator propagation**: All components receive the same allocator
2. **Snapshot ownership**: Caller owns snapshot and must call `deinit()`
3. **OSC events**: Events own their payload/rationale strings
4. **Plan parsing**: Parsed plan owns all string data

### Resource Cleanup

```zig
// Runtime cleanup
runtime.shutdown();

// Snapshot cleanup
snapshot.deinit(allocator);

// Plan cleanup
plan.deinit(allocator);

// Audit cleanup
audit.deinit(allocator);
```

## Error Handling

### Error Types

| Error | Cause | Recovery |
|-------|-------|----------|
| `KeyEncoderCreationFailed` | libghostty initialization | Fatal |
| `SgrParserCreationFailed` | libghostty initialization | Fatal |
| `OscParserCreationFailed` | libghostty initialization | Fatal |
| `CursorOutOfBounds` | Invalid framebuffer access | Skip operation |
| `ValidationFailed` | LLM returned invalid plan | Retry with backoff |
| `OutOfMemory` | Allocation failure | Return error |

### Retry Strategy

For LLM plan generation:

```zig
pub fn generatePlan(allocator, query, config, max_retries, snapshot) !CommandPlan {
    var attempt: u8 = 0;
    while (attempt < max_retries) : (attempt += 1) {
        const json_str = try generate(allocator, query, config, snapshot);
        defer allocator.free(json_str);

        if (CommandPlan.fromJson(allocator, json_str)) |plan| {
            return plan;
        } else |err| {
            log.warn("Attempt {}/{}: {}", .{attempt + 1, max_retries, err});
            continue;
        }
    }
    return error.ValidationFailed;
}
```

## Thread Safety

The Terminal Runtime is designed for single-threaded use within a shell context:

- **Not thread-safe**: State mutations are not synchronized
- **Snapshot immutability**: Snapshots are safe to pass between threads
- **Allocation safety**: Uses provided allocator consistently

For concurrent access (future feature), consider:
- Mutex protection around state mutations
- Reader-writer locks for snapshot access
- Message-passing for cross-thread communication

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SLY_PROVIDER` | (auto-detect) | LLM provider selection |
| `SLY_PROMPT_EXTEND` | - | Custom system prompt extension |
| `SLY_*_MODEL` | (provider default) | Model selection per provider |
| `SLY_*_URL` | (provider default) | API endpoint override |

### Policy Configuration

```zig
pub const PolicyConfig = struct {
    allow_title_changes: bool = true,
    confirm_title_changes: bool = false,
    allow_hyperlinks: bool = true,
    confirm_hyperlinks: bool = false,
    allow_palette_changes: bool = false,
    confirm_palette_changes: bool = true,
    allow_osc52: bool = true,
    confirm_osc52: bool = true,
    allow_current_directory: bool = true,
    allow_shell_integration: bool = true,
    allow_notifications: bool = false,
    confirm_notifications: bool = true,
    default_unknown: PolicyVerdict = .confirm,
};
```
