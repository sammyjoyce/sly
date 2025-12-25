# feedBytes() Implementation Guide

**File:** `src/terminal_runtime.zig` (line 237)  
**Current Status:** Stubbed with TODO comments  
**Estimated Effort:** 2-3 days  
**Blocks:** Phase 2 completion, Phase 4 OSC routing, Phase 5 snapshot comparison, Phase 7 provider integration

## Current Implementation

```zig
/// Feed bytes from PTY output into the terminal
pub fn feedBytes(self: *TerminalRuntime, bytes: []const u8) !void {
    // NOTE: This is a placeholder implementation for Phase 1
    // In Phase 2, we'll add full VT processing with framebuffer updates

    std.log.debug("Feed {} bytes to terminal (Phase 1: parsers ready, full VT processing pending)", .{bytes.len});

    // Parsers are initialized and ready:
    // - self.sgr_parser for styling sequences
    // - self.osc_parser for OSC commands
    // - Next phase will wire these into actual byte stream processing
    _ = self; // Will be used in Phase 2
}
```

## What Already Works

✅ **SGR Parser** - Fully initialized and tested (test at line 618):
- `ghostty_sgr_set_params()` - Load SGR parameter sequence
- `ghostty_sgr_next()` - Iterate attributes
- Extracts: bold, colors (FG/BG), underline, unknown attributes

✅ **OSC Parser** - Fully initialized and tested (test at line 650):
- `ghostty_osc_next()` - Feed bytes one at a time
- `ghostty_osc_end()` - Finalize with terminator (BEL/ST)
- `ghostty_osc_command_type()` - Classify command
- `ghostty_osc_command_data()` - Extract payload

✅ **OSC Processing** - Complete method exists (line 251):
- `processOscCommand()` integrates with PolicyEngine
- Extracts window titles, hyperlinks, palette changes
- Records events with policy verdicts

✅ **Test Infrastructure** - Proves parsers work:
- Bold+red parsing test passes
- Window title extraction test passes

## Implementation Strategy

### Phase 2A: Basic Escape Sequence Detection (Day 1)

**Goal:** Detect and route escape sequences to appropriate parsers.

**Approach:**
1. Add state machine for tracking escape sequence boundaries
2. Detect `ESC[` (CSI) for SGR sequences
3. Detect `ESC]` (OSC) for OSC sequences
4. Route bytes to appropriate parser

**Code Structure:**
```zig
const ParseState = enum {
    normal,
    escape,      // Saw ESC
    csi,         // Saw ESC[, collecting SGR params
    osc,         // Saw ESC], collecting OSC data
};

pub fn feedBytes(self: *TerminalRuntime, bytes: []const u8) !void {
    var state = ParseState.normal;
    var param_start: usize = 0;
    
    for (bytes, 0..) |byte, i| {
        switch (state) {
            .normal => {
                if (byte == 0x1b) { // ESC
                    state = .escape;
                } else {
                    // Regular character - add to framebuffer
                    try self.addChar(byte);
                }
            },
            .escape => {
                if (byte == '[') {
                    state = .csi;
                    param_start = i + 1;
                } else if (byte == ']') {
                    state = .osc;
                    param_start = i + 1;
                }
            },
            .csi => {
                if (isSgrTerminator(byte)) {
                    try self.processSgrSequence(bytes[param_start..i]);
                    state = .normal;
                }
            },
            .osc => {
                ghostty.osc_next(self.osc_parser, byte);
                if (byte == 0x07 or byte == 0x9c) { // BEL or ST
                    const command = ghostty.osc_end(self.osc_parser, byte);
                    try self.processOscCommand(command);
                    state = .normal;
                }
            },
        }
    }
}
```

**Test:** Feed `"\x1b[1;31mHello\x1b[0m"` → should parse bold+red, display "Hello", reset.

### Phase 2B: SGR Processing (Day 1-2)

**Goal:** Extract styling attributes and apply to framebuffer.

**Add to TerminalRuntime:**
```zig
const Cell = struct {
    char: u8,
    fg_color: ?u8 = null,
    bg_color: ?u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: ghostty.SgrUnderline = .none,
};

framebuffer: std.ArrayList(std.ArrayList(Cell)),
current_style: Cell = .{},
cursor_row: u16 = 0,
cursor_col: u16 = 0,
```

**Implement `processSgrSequence()`:**
```zig
fn processSgrSequence(self: *TerminalRuntime, param_bytes: []const u8) !void {
    // Parse params as semicolon-separated integers
    var params: [16]u16 = undefined;
    const param_count = try parseParams(param_bytes, &params);
    
    // Feed to SGR parser
    const result = ghostty.sgr_set_params(
        self.sgr_parser,
        &params,
        null,
        param_count,
    );
    
    if (!ghostty.isSuccess(result)) {
        return error.SgrParseFailed;
    }
    
    // Extract attributes and update current_style
    var attr: ghostty.SgrAttribute = undefined;
    while (ghostty.sgr_next(self.sgr_parser, &attr)) {
        switch (attr.tag) {
            ghostty.SGR_ATTR_BOLD => {
                self.current_style.bold = true;
            },
            ghostty.SGR_ATTR_FG_8 => {
                self.current_style.fg_color = attr.value.fg_8;
            },
            ghostty.SGR_ATTR_BG_8 => {
                self.current_style.bg_color = attr.value.bg_8;
            },
            ghostty.SGR_ATTR_UNDERLINE => {
                self.current_style.underline = attr.value.underline;
            },
            ghostty.SGR_ATTR_RESET => {
                self.current_style = .{};
            },
            else => {
                // Log unknown attributes for observability
                std.log.debug("Unknown SGR attribute: {}", .{attr.tag});
            },
        }
    }
}
```

**Test:** Parse `"\x1b[1;31m"` → `current_style.bold = true, fg_color = 1`

### Phase 2C: Framebuffer Management (Day 2)

**Goal:** Store characters with styling in a 2D grid.

**Implement `addChar()`:**
```zig
fn addChar(self: *TerminalRuntime, char: u8) !void {
    // Handle special characters
    switch (char) {
        '\r' => {
            self.cursor_col = 0;
            return;
        },
        '\n' => {
            self.cursor_row += 1;
            self.cursor_col = 0;
            if (self.cursor_row >= self.rows) {
                try self.scrollUp();
            }
            return;
        },
        '\t' => {
            // Tab: advance to next 8-column boundary
            self.cursor_col = ((self.cursor_col / 8) + 1) * 8;
            return;
        },
        else => {},
    }
    
    // Ensure framebuffer has enough rows
    while (self.framebuffer.items.len <= self.cursor_row) {
        var row = std.ArrayList(Cell).init(self.allocator);
        try self.framebuffer.append(row);
    }
    
    // Ensure current row has enough cells
    var row = &self.framebuffer.items[self.cursor_row];
    while (row.items.len <= self.cursor_col) {
        try row.append(Cell{});
    }
    
    // Write cell with current style
    row.items[self.cursor_col] = Cell{
        .char = char,
        .fg_color = self.current_style.fg_color,
        .bg_color = self.current_style.bg_color,
        .bold = self.current_style.bold,
        .italic = self.current_style.italic,
        .underline = self.current_style.underline,
    };
    
    self.cursor_col += 1;
    if (self.cursor_col >= self.cols) {
        self.cursor_col = 0;
        self.cursor_row += 1;
        if (self.cursor_row >= self.rows) {
            try self.scrollUp();
        }
    }
}

fn scrollUp(self: *TerminalRuntime) !void {
    // Move first row to scrollback
    // Remove first row from framebuffer
    // Cursor row -= 1
    // TODO: Implement scrollback buffer
}
```

**Test:** Feed `"Hello\nWorld"` → framebuffer has 2 rows with text.

### Phase 2D: Snapshot Integration (Day 3)

**Goal:** Populate Snapshot struct with framebuffer data.

**Update Snapshot struct:**
```zig
pub const Snapshot = struct {
    hash: u64,
    timestamp: i64,
    rows: u16,
    cols: u16,
    
    /// Viewport content (current visible screen)
    framebuffer: []const []const Cell,
    
    /// Cursor position
    cursor_row: u16,
    cursor_col: u16,
    
    /// Recent OSC events
    osc_events: []const OscEvent,
    
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.framebuffer) |row| {
            allocator.free(row);
        }
        allocator.free(self.framebuffer);
        allocator.free(self.osc_events);
    }
};
```

**Update `snapshot()` method:**
```zig
pub fn snapshot(self: *TerminalRuntime, options: SnapshotOptions) !Snapshot {
    // Copy framebuffer
    var fb_copy = try self.allocator.alloc([]Cell, self.framebuffer.items.len);
    for (self.framebuffer.items, 0..) |row, i| {
        fb_copy[i] = try self.allocator.dupe(Cell, row.items);
    }
    
    // Copy OSC events
    const osc_copy = try self.allocator.dupe(OscEvent, self.osc_events.items);
    
    // Compute hash
    const hash = computeHash(fb_copy, self.cursor_row, self.cursor_col);
    
    return Snapshot{
        .hash = hash,
        .timestamp = std.time.milliTimestamp(),
        .rows = self.rows,
        .cols = self.cols,
        .framebuffer = fb_copy,
        .cursor_row = self.cursor_row,
        .cursor_col = self.cursor_col,
        .osc_events = osc_copy,
    };
}

fn computeHash(framebuffer: []const []const Cell, cursor_row: u16, cursor_col: u16) u64 {
    var hasher = std.hash.Wyhash.init(0);
    
    for (framebuffer) |row| {
        for (row) |cell| {
            hasher.update(&[_]u8{cell.char});
            if (cell.fg_color) |c| hasher.update(&[_]u8{c});
            if (cell.bg_color) |c| hasher.update(&[_]u8{c});
            hasher.update(&[_]u8{@intFromBool(cell.bold)});
        }
    }
    
    hasher.update(std.mem.asBytes(&cursor_row));
    hasher.update(std.mem.asBytes(&cursor_col));
    
    return hasher.final();
}
```

**Test:** Create snapshot → hash changes when framebuffer changes.

## Testing Strategy

### Unit Tests (add to `test_ghostty.zig`)

```zig
test "feedBytes - plain text" {
    const testing = std.testing;
    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();
    
    try runtime.feedBytes("Hello World");
    
    const snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 0), snap.cursor_row);
    try testing.expectEqual(@as(u16, 11), snap.cursor_col);
    try testing.expectEqual(@as(u8, 'H'), snap.framebuffer[0][0].char);
}

test "feedBytes - SGR bold and color" {
    const testing = std.testing;
    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();
    
    try runtime.feedBytes("\x1b[1;31mRED\x1b[0m");
    
    const snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);
    
    try testing.expect(snap.framebuffer[0][0].bold);
    try testing.expectEqual(@as(u8, 1), snap.framebuffer[0][0].fg_color.?);
}

test "feedBytes - OSC window title" {
    const testing = std.testing;
    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();
    
    try runtime.feedBytes("\x1b]2;Test Title\x07");
    
    const snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);
    
    try testing.expectEqual(@as(usize, 1), snap.osc_events.len);
    try testing.expectEqual(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, snap.osc_events[0].command_type);
}
```

### Integration Tests (golden PTY fixtures)

Create `tests/pty_fixtures/`:
- `basic.txt` - Plain text output
- `colors.txt` - SGR color sequences
- `mixed.txt` - Text + OSC + SGR
- `scrolling.txt` - Many lines causing scrollback

Run fixtures through `feedBytes()`, assert snapshot hashes match expected values.

## Success Criteria

✅ **Day 1 Complete:**
- Escape sequence state machine works
- SGR sequences detected and routed
- OSC sequences detected and routed
- Basic framebuffer stores characters

✅ **Day 2 Complete:**
- SGR attributes extracted (colors, bold, underline)
- Framebuffer stores styled cells
- Cursor positioning works (newlines, tabs)
- Unit tests pass

✅ **Day 3 Complete:**
- Snapshot captures full framebuffer state
- Snapshot hash implementation works
- OSC events included in snapshot
- Golden test fixtures pass

## Unblocking Impact

Once `feedBytes()` is complete:
- **Phase 4** (OSC routing): Can finish OSC event bus
- **Phase 5** (Planner): Can implement snapshot comparison (line 308)
- **Phase 7** (Providers): Can include snapshots in prompts
- **Phase 9** (Observability): Can create golden test harness

**Total unblocked work:** ~15-20 days of implementation across 4 phases.

## References

- **Current stub**: `src/terminal_runtime.zig` line 237
- **SGR test**: `src/terminal_runtime.zig` line 618
- **OSC test**: `src/terminal_runtime.zig` line 650
- **OSC processing**: `src/terminal_runtime.zig` line 251
- **Snapshot struct**: `src/terminal_runtime.zig` line 562
- **Command planner usage**: `src/command_planner.zig` line 366
