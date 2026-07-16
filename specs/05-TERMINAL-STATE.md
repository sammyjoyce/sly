# Terminal State Specification

## Overview

Terminal state management encompasses the framebuffer (visible screen content), SGR parsing (text styling), OSC handling (operating system commands), and snapshot creation. This document specifies how sly maintains and exposes terminal state using libghostty-vt.

## Framebuffer Architecture

### Grid Model

The terminal screen is a 2D grid of cells:

```
┌───────────────────────────────────────────────────────────────────┐
│ Column 0   Column 1   Column 2   ...   Column (cols-1)            │
├───────────────────────────────────────────────────────────────────┤
│ Row 0:  [Cell] [Cell] [Cell] [Cell] [Cell] [Cell] [Cell] ...     │
│ Row 1:  [Cell] [Cell] [Cell] [Cell] [Cell] [Cell] [Cell] ...     │
│ Row 2:  [Cell] [Cell] [Cell] [Cell] [Cell] [Cell] [Cell] ...     │
│   ...                                                             │
│ Row (rows-1): [Cell] [Cell] [Cell] ...                           │
└───────────────────────────────────────────────────────────────────┘
```

### Cell Structure

```zig
pub const Cell = struct {
    /// UTF-8 character (simplified to single byte for ASCII)
    char: u8 = ' ',

    /// Foreground color (0-15 for standard, 16-255 for extended)
    fg_color: ?u8 = null,

    /// Background color
    bg_color: ?u8 = null,

    /// Bold text attribute
    bold: bool = false,

    /// Italic text attribute
    italic: bool = false,

    /// Underline style
    underline: SgrUnderline = SGR_UNDERLINE_NONE,
};
```

### Underline Styles

```zig
pub const SgrUnderline = enum {
    NONE   = 0,  // No underline
    SINGLE = 1,  // Single underline
    DOUBLE = 2,  // Double underline
    CURLY  = 3,  // Curly/wavy underline
    DOTTED = 4,  // Dotted underline
    DASHED = 5,  // Dashed underline
};
```

## Cursor State

### Cursor Model

```zig
pub const CursorState = struct {
    /// Current row (0-indexed)
    row: u16 = 0,

    /// Current column (0-indexed)
    col: u16 = 0,

    /// Cursor visibility
    visible: bool = true,

    /// Cursor style (block, underline, bar)
    style: CursorStyle = .block,

    /// Blinking enabled
    blinking: bool = true,
};

pub const CursorStyle = enum {
    block,
    underline,
    bar,
};
```

### Cursor Movement

| Operation | Description |
|-----------|-------------|
| Write char | Advance cursor, wrap at end of line |
| Carriage return (`\r`) | Move to column 0 |
| Line feed (`\n`) | Move to next line, scroll if needed |
| Backspace (`\b`) | Move left one column (minimum 0) |
| Tab (`\t`) | Move to next 8-column boundary |

### Scrolling

When cursor moves below the last row:

```
Before scroll:
┌─────────────────────┐
│ Line 1              │
│ Line 2              │
│ Line 3              │
│ New content...▌     │  ← Cursor at row 3 (0-indexed)
└─────────────────────┘

After scroll (cursor at row 23 in 24-row terminal):
┌─────────────────────┐
│ Line 2              │
│ Line 3              │
│ New content...      │
│ ▌                   │  ← Cursor stays at row 23
└─────────────────────┘
```

## SGR Parsing

### SGR (Select Graphic Rendition) API

```zig
// Create parser
var parser: GhosttySgrParser = undefined;
ghostty_sgr_new(allocator, &parser);

// Set parameters from CSI sequence
// ESC[1;31m → params = [1, 31]
const params = [_]u16{ 1, 31 };
ghostty_sgr_set_params(parser, &params, null, params.len);

// Iterate attributes
var attr: GhosttySgrAttribute = undefined;
while (ghostty_sgr_next(parser, &attr)) {
    switch (attr.tag) {
        GHOSTTY_SGR_ATTR_BOLD => {
            // Enable bold
        },
        GHOSTTY_SGR_ATTR_FG_8 => {
            // Set foreground color (8-color palette)
            const color = attr.value.fg_8;
        },
        // ... handle other attributes
    }
}

ghostty_sgr_free(parser);
```

### SGR Attribute Tags

| Tag | Description | Value Type |
|-----|-------------|------------|
| `SGR_ATTR_UNSET` | Reset all attributes | None |
| `SGR_ATTR_BOLD` | Enable bold | None |
| `SGR_ATTR_RESET_BOLD` | Disable bold | None |
| `SGR_ATTR_FAINT` | Enable faint/dim | None |
| `SGR_ATTR_ITALIC` | Enable italic | None |
| `SGR_ATTR_RESET_ITALIC` | Disable italic | None |
| `SGR_ATTR_UNDERLINE` | Set underline style | SgrUnderline |
| `SGR_ATTR_RESET_UNDERLINE` | Disable underline | None |
| `SGR_ATTR_INVERSE` | Enable inverse video | None |
| `SGR_ATTR_RESET_INVERSE` | Disable inverse | None |
| `SGR_ATTR_FG_8` | 8-color foreground | u8 (0-7) |
| `SGR_ATTR_BG_8` | 8-color background | u8 (0-7) |
| `SGR_ATTR_FG_256` | 256-color foreground | u8 (0-255) |
| `SGR_ATTR_BG_256` | 256-color background | u8 (0-255) |
| `SGR_ATTR_DIRECT_COLOR_FG` | RGB foreground | ColorRGB |
| `SGR_ATTR_DIRECT_COLOR_BG` | RGB background | ColorRGB |

### Color Palette

Standard 8 colors (0-7):

| Index | Color |
|-------|-------|
| 0 | Black |
| 1 | Red |
| 2 | Green |
| 3 | Yellow |
| 4 | Blue |
| 5 | Magenta |
| 6 | Cyan |
| 7 | White |

Bright variants (8-15):

| Index | Color |
|-------|-------|
| 8 | Bright Black |
| 9 | Bright Red |
| 10 | Bright Green |
| 11 | Bright Yellow |
| 12 | Bright Blue |
| 13 | Bright Magenta |
| 14 | Bright Cyan |
| 15 | Bright White |

Extended colors (16-255): 6x6x6 color cube + 24 grayscale

### SGR Sequence Examples

| Sequence | Meaning |
|----------|---------|
| `ESC[0m` | Reset all attributes |
| `ESC[1m` | Bold |
| `ESC[3m` | Italic |
| `ESC[4m` | Underline |
| `ESC[4:3m` | Curly underline |
| `ESC[31m` | Red foreground |
| `ESC[41m` | Red background |
| `ESC[1;31m` | Bold + red foreground |
| `ESC[38;5;196m` | 256-color foreground (color 196) |
| `ESC[38;2;255;128;0m` | RGB foreground (orange) |

## OSC Parsing

### OSC (Operating System Command) API

```zig
// Create parser
var parser: GhosttyOscParser = undefined;
ghostty_osc_new(allocator, &parser);

// Feed OSC bytes (after ESC])
// ESC]2;Window Title\x07
const osc_content = "2;Window Title";
for (osc_content) |byte| {
    ghostty_osc_next(parser, byte);
}

// Finalize with terminator (BEL=0x07 or ST=0x9C)
const command = ghostty_osc_end(parser, 0x07);

// Query command type
const cmd_type = ghostty_osc_command_type(command);

// Extract data based on type
if (cmd_type == GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE) {
    var title_ptr: [*c]const u8 = undefined;
    if (ghostty_osc_command_data(command, GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR, &title_ptr)) {
        const title = std.mem.span(title_ptr);
    }
}

ghostty_osc_free(parser);
```

### OSC Command Types

| Command | Number | Description |
|---------|--------|-------------|
| `CHANGE_WINDOW_TITLE` | 2 | Set window title |
| `CHANGE_WINDOW_ICON` | 1 | Set icon name |
| `REPORT_PWD` | 7 | Report current directory |
| `CLIPBOARD_CONTENTS` | 52 | Clipboard read/write |
| `PROMPT_START` | 133;A | Shell prompt start marker |
| `PROMPT_END` | 133;B | Shell prompt end marker |
| `END_OF_INPUT` | 133;C | End of user input |
| `END_OF_COMMAND` | 133;D | End of command output |
| `HYPERLINK_START` | 8 | Start hyperlink |
| `HYPERLINK_END` | 8;; | End hyperlink |
| `SHOW_DESKTOP_NOTIFICATION` | 9 | Desktop notification |
| `COLOR_OPERATION` | 10-19 | Query/set terminal colors |
| `KITTY_COLOR_PROTOCOL` | 21 | Kitty color protocol |

### OSC Event Structure

```zig
pub const OscEvent = struct {
    /// The type of OSC command
    command_type: OscCommandType,

    /// Optional payload data (owned)
    payload: ?[]u8 = null,

    /// Policy decision: allowed automatically?
    allowed: bool = true,

    /// Requires user confirmation?
    needs_confirmation: bool = false,

    /// Policy rationale (owned)
    rationale: ?[]u8 = null,
};
```

### Shell Integration Markers (OSC 133)

Modern shells use OSC 133 for semantic integration:

```
┌─────────────────────────────────────────────────────────────────┐
│ ESC]133;A\x07  Prompt Start                                     │
│ $ ▌                                                             │
│ ESC]133;B\x07  Prompt End (user input follows)                  │
│ $ ls -la                                                        │
│ ESC]133;C\x07  End of Input (command output follows)            │
│ total 42                                                        │
│ drwxr-xr-x  5 user group ...                                    │
│ ESC]133;D;0\x07  End of Command (exit code in parameter)        │
└─────────────────────────────────────────────────────────────────┘
```

## VT Sequence Parsing

### Parse State Machine

```zig
const ParseState = enum {
    normal,   // Regular text
    escape,   // Saw ESC (0x1B)
    csi,      // Saw ESC[, collecting parameters
    osc,      // Saw ESC], collecting OSC data
};
```

### State Transitions

```
                 printable
         ┌────────────────────┐
         │                    │
         ▼                    │
     ┌────────┐              │
     │ NORMAL │ ◄────────────┘
     └───┬────┘
         │ ESC (0x1B)
         ▼
     ┌────────┐
     │ ESCAPE │
     └───┬────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
 [  ┌───┐  ]  ┌───┐
    │CSI│     │OSC│
    └─┬─┘     └─┬─┘
      │         │
      ▼         ▼
   'm' →    0x07/ST →
   SGR       command
```

### CSI Sequence Structure

```
ESC [ <params> <intermediate> <final>

Example: ESC[1;31m
- ESC[  = CSI introducer
- 1;31  = parameters (semicolon-separated)
- m     = final byte (SGR command)
```

### Parameter Handling

```zig
fn processCsiSequence(self: *TerminalRuntime, params: []const u8, final: u8) !void {
    switch (final) {
        'm' => {
            // SGR - styling
            try self.processSgrSequence(params);
        },
        'H' => {
            // CUP - cursor position
            // Parse row;col from params
        },
        'J' => {
            // ED - erase in display
        },
        'K' => {
            // EL - erase in line
        },
        // ... other CSI commands
    }
}
```

## Snapshot System

### Snapshot Creation

```zig
pub fn snapshot(self: *TerminalRuntime, options: SnapshotOptions) !Snapshot {
    // Deep copy framebuffer
    var fb_copy = try self.allocator.alloc([]Cell, self.framebuffer.items.len);
    for (self.framebuffer.items, 0..) |row, i| {
        fb_copy[i] = try self.allocator.dupe(Cell, row.items);
    }

    // Copy OSC events
    const osc_copy = try self.allocator.dupe(OscEvent, self.osc_events.items);

    // Compute content hash
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
```

### Snapshot Options

```zig
pub const SnapshotOptions = struct {
    /// Include scrollback buffer in snapshot
    include_scrollback: bool = true,

    /// Maximum scrollback lines to include
    scrollback_lines: u32 = 100,

    /// Include styling information
    include_styling: bool = true,

    /// Include OSC events
    include_osc_events: bool = true,
};
```

### Hash Computation

Wyhash for efficient content fingerprinting:

```zig
fn computeHash(framebuffer: []const []const Cell, cursor_row: u16, cursor_col: u16) u64 {
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

### Hash Use Cases

| Use Case | Description |
|----------|-------------|
| Change detection | Compare snapshot hashes to detect content changes |
| Audit trail | Include hash in plan execution audits |
| Caching | Cache LLM responses keyed by context hash |
| Debugging | Trace state changes through hash sequence |

## Snapshot for LLM Context

### Text Extraction

Convert framebuffer to text for LLM prompt:

```zig
pub fn formatSnapshotForPrompt(allocator: Allocator, snapshot: *const Snapshot) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);

    // Header
    try buf.appendSlice("Terminal State (");
    try std.fmt.format(buf.writer(), "{}x{}):\n", .{snapshot.cols, snapshot.rows});

    // Cursor position
    try std.fmt.format(buf.writer(), "Cursor: row {}, col {}\n", .{
        snapshot.cursor_row, snapshot.cursor_col
    });

    // Extract non-empty lines (last N)
    var line_count: usize = 0;
    const max_lines = 10;

    for (snapshot.framebuffer) |row| {
        if (line_count >= max_lines) break;

        // Check if row has content
        var has_content = false;
        for (row) |cell| {
            if (cell.char != ' ' and cell.char != 0) {
                has_content = true;
                break;
            }
        }

        if (has_content) {
            try buf.appendSlice("  | ");
            for (row) |cell| {
                if (cell.char != 0) {
                    try buf.append(cell.char);
                }
            }
            // Trim trailing spaces
            while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
                _ = buf.pop();
            }
            try buf.append('\n');
            line_count += 1;
        }
    }

    // Include safe OSC events
    if (snapshot.osc_events.len > 0) {
        try buf.appendSlice("\nRecent Shell Events:\n");
        for (snapshot.osc_events) |event| {
            const name = switch (event.command_type) {
                OSC_COMMAND_CHANGE_WINDOW_TITLE => "Title Change",
                OSC_COMMAND_REPORT_PWD => "Directory Change",
                OSC_COMMAND_PROMPT_START => "Prompt Start",
                // ... etc
                else => continue,  // Skip sensitive events
            };
            try std.fmt.format(buf.writer(), "  - {s}\n", .{name});
        }
    }

    return buf.toOwnedSlice();
}
```

### Privacy Filtering

Exclude sensitive data from LLM context:

```zig
fn shouldIncludeOscEvent(event: *const OscEvent) bool {
    return switch (event.command_type) {
        // Safe to include
        OSC_COMMAND_CHANGE_WINDOW_TITLE,
        OSC_COMMAND_REPORT_PWD,
        OSC_COMMAND_PROMPT_START,
        OSC_COMMAND_PROMPT_END,
        => true,

        // Exclude sensitive events
        OSC_COMMAND_CLIPBOARD_CONTENTS,
        OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION,
        => false,

        // Default: exclude unknown
        else => false,
    };
}
```

## Memory Management

### Framebuffer Allocation

```zig
// Initialize framebuffer
var framebuffer = std.ArrayList(std.ArrayList(Cell)).init(allocator);

for (0..rows) |_| {
    var row = std.ArrayList(Cell).initCapacity(allocator, cols);
    row.appendNTimesAssumeCapacity(Cell{}, cols);
    try framebuffer.append(row);
}
```

### Cleanup

```zig
pub fn shutdown(self: *TerminalRuntime) void {
    // Free framebuffer
    for (self.framebuffer.items) |*row| {
        row.deinit(self.allocator);
    }
    self.framebuffer.deinit(self.allocator);

    // Free OSC events
    for (self.osc_events.items) |*event| {
        event.deinit(self.allocator);
    }
    self.osc_events.deinit(self.allocator);

    // Free libghostty resources
    ghostty.osc_free(self.osc_parser);
    ghostty.sgr_free(self.sgr_parser);
    ghostty.key_encoder_free(self.key_encoder);
}
```

### Snapshot Ownership

```zig
// Caller owns snapshot, must call deinit
var snap = try runtime.snapshot(.{});
defer snap.deinit(allocator);

// Use snapshot...
const text = try formatSnapshotForPrompt(allocator, &snap);
defer allocator.free(text);
```

## Performance Considerations

### Framebuffer Updates

- Direct cell access: O(1)
- Row append (scroll): O(cols)
- Full redraw: O(rows × cols)

### Snapshot Creation

- Framebuffer copy: O(rows × cols)
- Hash computation: O(rows × cols)
- Memory: 2× framebuffer size during creation

### Optimization Strategies

1. **Lazy copying**: Only copy changed rows
2. **Delta snapshots**: Store diffs between snapshots
3. **Hash caching**: Cache hash when content unchanged
4. **Incremental parsing**: Track dirty regions
