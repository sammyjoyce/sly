# libghostty Integration

This document describes the integration of libghostty-vt into the sly project.

## Overview

sly now includes libghostty-vt, the virtual terminal emulator library extracted from [Ghostty](https://ghostty.org). This provides:

- **Key encoding**: Convert key events to terminal escape sequences (Kitty keyboard protocol support)
- **SGR parsing**: Parse Select Graphic Rendition (styling) sequences
- **OSC handling**: Process Operating System Command sequences
- **Paste safety**: Validate paste data before injection
- **Terminal state**: Maintain cursor, scrollback, and rendering state

## Architecture

### Components

1. **libghostty.zig** - Zig bindings to the libghostty-vt C API
2. **terminal_runtime.zig** - High-level terminal runtime built on libghostty
3. **vendor/ghostty/** - Vendored ghostty source code

### Phase 1 Implementation (Current)

The current implementation provides:

- ✅ Terminal runtime initialization and lifecycle management
- ✅ Key encoder with Kitty keyboard protocol support
- ✅ Terminal resize handling
- ✅ Skeleton for future features (OSC, SGR, paste, snapshots)

### Future Phases

- **Phase 2**: Output ingestion and snapshot infrastructure
- **Phase 3**: Input synthesis and paste guardrails
- **Phase 4**: OSC event bus and policy engine
- **Phase 5**: Command planner integration

## Building

The build system automatically builds libghostty-vt before building sly:

```bash
# Build sly (automatically builds libghostty-vt first)
zig build -Doptimize=ReleaseSafe

# This automatically:
# 1. Builds vendor/ghostty/zig-out/lib/libghostty-vt.so
# 2. Uses vendor/ghostty/zig-out/include/ghostty/vt.h headers
# 3. Links sly against libghostty-vt
```

To manually build just libghostty-vt:

```bash
zig build lib-ghostty
```

Run tests:

```bash
# Unit tests
zig build test

# Test libghostty integration
zig build test-ghostty
```

## Usage Example

```zig
const std = @import("std");
const TerminalRuntime = @import("terminal_runtime.zig").TerminalRuntime;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    // Create terminal runtime
    var runtime = try TerminalRuntime.init(gpa.allocator(), .{
        .cols = 80,
        .rows = 24,
        .enable_kitty_keyboard = true,
    });
    defer runtime.shutdown();
    
    // Resize terminal
    try runtime.resize(120, 40);
    
    // Feed PTY output (not yet implemented)
    // try runtime.feedBytes(pty_data);
    
    // Inject key events (not yet implemented)
    // const encoded = try runtime.injectKey(.press, key, mods);
}
```

## API Reference

### TerminalRuntime

#### init(allocator, params) -> !TerminalRuntime
Initialize a new terminal runtime.

**Parameters:**
- `allocator`: Zig allocator for runtime data structures
- `params`: InitParams struct with terminal configuration

#### shutdown()
Clean up and free all resources.

#### reset() -> !void
Reset terminal to initial state (not yet implemented).

#### resize(cols, rows) -> !void
Resize the terminal viewport.

#### feedBytes(bytes) -> !void
Feed PTY output bytes into the terminal (stub).

#### injectKey(action, key, mods) -> ![]const u8
Inject a key event and get encoded sequence (stub).

#### enqueuePaste(text) -> !void
Enqueue paste buffer with safety validation (stub).

#### drainOsc() -> ![]OscEvent
Drain OSC events since last call (stub).

#### snapshot(options) -> !Snapshot
Create immutable snapshot of terminal state (stub).

## Implementation Status

### Completed (Phase 1)
- [x] Zig bindings for libghostty C API
- [x] Key encoder integration
- [x] Terminal runtime skeleton
- [x] Lifecycle management (init/shutdown)
- [x] Resize handling
- [x] Integration tests

### Pending (Future Phases)
- [ ] VT output parsing (SGR, OSC)
- [ ] Scrollback management
- [ ] Paste safety validation
- [ ] OSC event bus
- [ ] Snapshot/state capture
- [ ] Command planner integration

## References

- [libghostty-vt Documentation](../vendor/ghostty/include/ghostty/vt.h)
- [Ghostty Repository](https://github.com/ghostty-org/ghostty)
- [Implementation Plan](../specs/libghostty-implementation-plan.md)
- [Design Decisions](../specs/libghostty-design-decisions.md)
- [Refactor Specification](../specs/libghostty-refactor-spec.md)
