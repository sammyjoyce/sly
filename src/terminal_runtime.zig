/// Terminal Runtime - libghostty-based terminal emulation runtime
///
/// This module provides the core terminal runtime built on libghostty-vt,
/// implementing the specification from specs/libghostty-refactor-spec.md.
///
/// Phase 1: Skeleton implementation with lifecycle management
/// Phase 3: Input synthesis & paste guardrails
/// Phase 4: OSC Bus & Policy Engine
const std = @import("std");
const ghostty = @import("libghostty.zig");
const policy = @import("policy_engine.zig");

/// Result of a paste validation
pub const PasteVerdict = enum {
    safe_auto, // Safe content, can auto-inject
    unsafe_needs_confirm, // Unsafe content, needs user confirmation
    rejected, // Rejected by policy
};

/// Result of a paste operation with policy decision
pub const PasteResult = struct {
    /// Encoded bytes ready for injection (null if rejected)
    bytes: ?[]const u8,

    /// Policy verdict
    verdict: PasteVerdict,

    /// Human-readable rationale
    rationale: []const u8,

    /// Free owned memory
    pub fn deinit(self: *PasteResult, allocator: std.mem.Allocator) void {
        if (self.bytes) |b| {
            allocator.free(b);
        }
        allocator.free(self.rationale);
    }
};

/// Parameters for initializing the terminal runtime
pub const InitParams = struct {
    /// Number of columns in the terminal
    cols: u16 = 80,

    /// Number of rows in the terminal
    rows: u16 = 24,

    /// Maximum scrollback depth (number of lines)
    scrollback_depth: u32 = 10000,

    /// Custom allocator for libghostty (null = use default)
    allocator: ?*const ghostty.Allocator = null,

    /// Enable Kitty keyboard protocol by default
    enable_kitty_keyboard: bool = true,

    /// Kitty keyboard flags
    kitty_flags: ghostty.KittyKeyFlags = ghostty.KITTY_KEY_ALL,

    /// Policy configuration for OSC commands and operations
    policy_config: policy.PolicyConfig = .{},
};

/// A single cell in the terminal framebuffer with character and styling
pub const Cell = struct {
    char: u8 = ' ',
    fg_color: Color = .none,
    bg_color: Color = .none,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: ghostty.SgrUnderline = 0, // GHOSTTY_SGR_UNDERLINE_NONE
    inverse: bool = false,
    strikethrough: bool = false,
    blink: bool = false,
};

/// Color representation supporting 8-color, 256-color, and RGB
pub const Color = union(enum) {
    none,
    indexed: u8, // 0-255 for 8/256 color palette
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .none => other == .none,
            .indexed => |i| switch (other) {
                .indexed => |j| i == j,
                else => false,
            },
            .rgb => |c1| switch (other) {
                .rgb => |c2| c1.r == c2.r and c1.g == c2.g and c1.b == c2.b,
                else => false,
            },
        };
    }
};

/// Cursor display style
pub const CursorStyle = enum {
    block,
    underline,
    bar,
};

/// Parse state for escape sequence detection
const ParseState = enum {
    normal, // Regular text
    escape, // Saw ESC (0x1b)
    csi, // Saw ESC[, collecting CSI params
    osc, // Saw ESC], collecting OSC data
};

/// Terminal Runtime manages all libghostty-vt interactions
pub const TerminalRuntime = struct {
    /// Zig allocator for runtime data structures
    allocator: std.mem.Allocator,

    /// libghostty key encoder
    key_encoder: ghostty.KeyEncoder = null,

    /// libghostty SGR parser
    sgr_parser: ghostty.SgrParser = null,

    /// libghostty OSC parser
    osc_parser: ghostty.OscParser = null,

    /// Policy engine for security decisions
    policy_engine: policy.PolicyEngine,

    /// Accumulated OSC events
    osc_events: std.ArrayList(OscEvent),

    /// Initialization parameters
    params: InitParams,

    /// Current terminal size
    cols: u16,
    rows: u16,

    /// Framebuffer: 2D grid of cells (rows x cols)
    framebuffer: std.ArrayList(std.ArrayList(Cell)),

    /// Scrollback buffer: lines that have scrolled off the top
    scrollback: std.ArrayList(std.ArrayList(Cell)),

    /// Current cursor position
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,

    /// Cursor visibility and style
    cursor_visible: bool = true,
    cursor_style: CursorStyle = .block,
    cursor_blinking: bool = true,

    /// Current styling attributes (applied to new characters)
    current_style: Cell = .{},

    /// Alternate screen buffer (used by vim, less, etc.)
    alternate_framebuffer: ?std.ArrayList(std.ArrayList(Cell)) = null,

    /// Whether we're currently in alternate screen mode
    is_alternate_screen: bool = false,

    /// Initialize a new terminal runtime
    pub fn init(allocator: std.mem.Allocator, params: InitParams) !TerminalRuntime {
        var runtime = TerminalRuntime{
            .allocator = allocator,
            .params = params,
            .cols = params.cols,
            .rows = params.rows,
            .policy_engine = policy.PolicyEngine.init(allocator, params.policy_config),
            .osc_events = .{},
            .framebuffer = .{},
            .scrollback = .{},
        };
        errdefer runtime.osc_events.deinit(allocator);
        errdefer runtime.scrollback.deinit(allocator);

        // Initialize framebuffer with empty rows
        errdefer runtime.framebuffer.deinit(allocator);
        for (0..params.rows) |_| {
            var row = std.ArrayList(Cell).initCapacity(allocator, params.cols) catch |err| {
                // Clean up any rows already created
                for (runtime.framebuffer.items) |*r| {
                    r.deinit(allocator);
                }
                runtime.framebuffer.deinit(allocator);
                return err;
            };
            // Fill row with empty cells
            row.appendNTimesAssumeCapacity(Cell{}, params.cols);
            runtime.framebuffer.append(allocator, row) catch |err| {
                row.deinit(allocator);
                // Clean up any rows already created
                for (runtime.framebuffer.items) |*r| {
                    r.deinit(allocator);
                }
                runtime.framebuffer.deinit(allocator);
                return err;
            };
        }

        // Create key encoder
        const encoder_result = ghostty.key_encoder_new(
            params.allocator,
            &runtime.key_encoder,
        );

        if (!ghostty.isSuccess(encoder_result)) {
            std.log.err("Failed to create key encoder: {s}", .{ghostty.resultMessage(encoder_result)});
            return error.KeyEncoderCreationFailed;
        }
        errdefer ghostty.key_encoder_free(runtime.key_encoder);

        // Enable Kitty keyboard protocol if requested
        if (params.enable_kitty_keyboard) {
            var flags = params.kitty_flags;
            ghostty.key_encoder_setopt(
                runtime.key_encoder,
                ghostty.KEY_ENCODER_OPT_KITTY_FLAGS,
                &flags,
            );
        }

        // Create SGR parser
        const sgr_result = ghostty.sgr_new(params.allocator, &runtime.sgr_parser);
        if (!ghostty.isSuccess(sgr_result)) {
            std.log.err("Failed to create SGR parser: {s}", .{ghostty.resultMessage(sgr_result)});
            return error.SgrParserCreationFailed;
        }
        errdefer ghostty.sgr_free(runtime.sgr_parser);

        // Create OSC parser
        const osc_result = ghostty.osc_new(params.allocator, &runtime.osc_parser);
        if (!ghostty.isSuccess(osc_result)) {
            std.log.err("Failed to create OSC parser: {s}", .{ghostty.resultMessage(osc_result)});
            return error.OscParserCreationFailed;
        }

        std.log.info("Terminal runtime initialized: {}x{} cols/rows, scrollback: {}, parsers: key+sgr+osc", .{
            params.cols,
            params.rows,
            params.scrollback_depth,
        });

        return runtime;
    }

    /// Shutdown and free all resources
    pub fn shutdown(self: *TerminalRuntime) void {
        if (self.osc_parser != null) {
            ghostty.osc_free(self.osc_parser);
            self.osc_parser = null;
        }

        if (self.sgr_parser != null) {
            ghostty.sgr_free(self.sgr_parser);
            self.sgr_parser = null;
        }

        if (self.key_encoder != null) {
            ghostty.key_encoder_free(self.key_encoder);
            self.key_encoder = null;
        }

        // Clean up framebuffer
        for (self.framebuffer.items) |*row| {
            row.deinit(self.allocator);
        }
        self.framebuffer.deinit(self.allocator);

        // Clean up alternate framebuffer if present
        if (self.alternate_framebuffer) |*alt_fb| {
            for (alt_fb.items) |*row| {
                row.deinit(self.allocator);
            }
            alt_fb.deinit(self.allocator);
            self.alternate_framebuffer = null;
        }

        // Clean up scrollback
        for (self.scrollback.items) |*row| {
            row.deinit(self.allocator);
        }
        self.scrollback.deinit(self.allocator);

        // Clean up OSC events
        for (self.osc_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.osc_events.deinit(self.allocator);

        const stats = self.policy_engine.getStats();
        std.log.info("Terminal runtime shutdown - {any}", .{stats});
    }

    /// Reset the terminal to initial state
    pub fn reset(self: *TerminalRuntime) !void {
        // Clear framebuffer - reset all cells to default
        for (self.framebuffer.items) |*row| {
            for (row.items) |*cell| {
                cell.* = Cell{};
            }
        }

        // Reset cursor position
        self.cursor_row = 0;
        self.cursor_col = 0;

        // Reset styling
        self.current_style = Cell{};

        // Clear OSC events
        for (self.osc_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.osc_events.clearRetainingCapacity();

        std.log.info("Terminal runtime reset", .{});
    }

    /// Resize the terminal viewport with content reflow
    pub fn resize(self: *TerminalRuntime, cols: u16, rows: u16) !void {
        const old_cols = self.cols;
        const old_rows = self.rows;

        // Handle column resize - adjust each row
        if (cols != old_cols) {
            // Resize existing framebuffer rows
            for (self.framebuffer.items) |*row| {
                if (cols > old_cols) {
                    // Expand: add empty cells
                    try row.ensureTotalCapacity(self.allocator, cols);
                    const to_add = cols - @as(u16, @intCast(row.items.len));
                    row.appendNTimesAssumeCapacity(Cell{}, to_add);
                } else {
                    // Shrink: truncate (content reflow would be more sophisticated)
                    row.shrinkRetainingCapacity(cols);
                }
            }

            // Resize scrollback rows
            for (self.scrollback.items) |*row| {
                if (cols > old_cols) {
                    try row.ensureTotalCapacity(self.allocator, cols);
                    const to_add = cols - @as(u16, @intCast(row.items.len));
                    row.appendNTimesAssumeCapacity(Cell{}, to_add);
                } else {
                    row.shrinkRetainingCapacity(cols);
                }
            }
        }

        // Handle row resize
        if (rows != old_rows) {
            if (rows > old_rows) {
                // Expand: add empty rows at bottom
                for (0..(rows - old_rows)) |_| {
                    var new_row = try std.ArrayList(Cell).initCapacity(self.allocator, cols);
                    new_row.appendNTimesAssumeCapacity(Cell{}, cols);
                    try self.framebuffer.append(self.allocator, new_row);
                }
            } else {
                // Shrink: move excess rows to scrollback
                while (self.framebuffer.items.len > rows) {
                    var removed_row = self.framebuffer.orderedRemove(0);

                    // Add to scrollback if within depth limit
                    if (self.scrollback.items.len < self.params.scrollback_depth) {
                        try self.scrollback.append(self.allocator, removed_row);
                    } else if (self.params.scrollback_depth > 0) {
                        var oldest = self.scrollback.orderedRemove(0);
                        oldest.deinit(self.allocator);
                        try self.scrollback.append(self.allocator, removed_row);
                    } else {
                        removed_row.deinit(self.allocator);
                    }
                }
            }
        }

        self.cols = cols;
        self.rows = rows;

        // Clamp cursor position to new bounds
        if (self.cursor_col >= cols) {
            self.cursor_col = if (cols > 0) cols - 1 else 0;
        }
        if (self.cursor_row >= rows) {
            self.cursor_row = if (rows > 0) rows - 1 else 0;
        }

        std.log.info("Terminal resized from {any}x{any} to {any}x{any}", .{ old_cols, old_rows, cols, rows });
    }

    /// Key encoder configuration options
    pub const KeyEncoderOptions = struct {
        /// Enable cursor key application mode
        cursor_key_application: ?bool = null,

        /// Enable keypad key application mode
        keypad_key_application: ?bool = null,

        /// Ignore keypad with numlock enabled
        ignore_keypad_with_numlock: ?bool = null,

        /// Use ESC prefix for Alt key
        alt_esc_prefix: ?bool = null,

        /// Modify other keys state (level 2)
        modify_other_keys_state_2: ?bool = null,

        /// macOS: treat Option as Alt
        macos_option_as_alt: ?bool = null,

        /// Kitty keyboard protocol flags
        kitty_flags: ?ghostty.KittyKeyFlags = null,
    };

    /// Configure key encoder options at runtime
    pub fn setKeyEncoderOptions(self: *TerminalRuntime, options: KeyEncoderOptions) void {
        if (options.cursor_key_application) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION,
                &val,
            );
            std.log.debug("Set cursor_key_application: {any}", .{value});
        }

        if (options.keypad_key_application) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION,
                &val,
            );
            std.log.debug("Set keypad_key_application: {any}", .{value});
        }

        if (options.ignore_keypad_with_numlock) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK,
                &val,
            );
            std.log.debug("Set ignore_keypad_with_numlock: {any}", .{value});
        }

        if (options.alt_esc_prefix) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_ALT_ESC_PREFIX,
                &val,
            );
            std.log.debug("Set alt_esc_prefix: {any}", .{value});
        }

        if (options.modify_other_keys_state_2) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2,
                &val,
            );
            std.log.debug("Set modify_other_keys_state_2: {any}", .{value});
        }

        if (options.macos_option_as_alt) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                &val,
            );
            std.log.debug("Set macos_option_as_alt: {any}", .{value});
        }

        if (options.kitty_flags) |value| {
            var val = value;
            ghostty.key_encoder_setopt(
                self.key_encoder,
                ghostty.KEY_ENCODER_OPT_KITTY_FLAGS,
                &val,
            );
            std.log.debug("Set kitty_flags: {any}", .{value});
        }
    }

    /// Feed bytes from PTY output into the terminal
    pub fn feedBytes(self: *TerminalRuntime, bytes: []const u8) !void {
        std.log.debug("Feeding {} bytes to terminal", .{bytes.len});

        var state = ParseState.normal;
        var param_start: usize = 0;
        var param_buffer = std.ArrayList(u8){};
        defer param_buffer.deinit(self.allocator);

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
                        // CSI sequence (SGR, cursor control, etc.)
                        state = .csi;
                        param_start = i + 1;
                        param_buffer.clearRetainingCapacity();
                    } else if (byte == ']') {
                        // OSC sequence
                        state = .osc;
                        param_start = i + 1;
                    } else {
                        // Unknown escape sequence, return to normal
                        state = .normal;
                    }
                },
                .csi => {
                    // Collect CSI parameters until we hit the terminator
                    if (byte >= 0x40 and byte <= 0x7e) {
                        // Terminator byte (@ through ~)
                        const params_slice = if (param_buffer.items.len > 0)
                            param_buffer.items
                        else
                            "";

                        switch (byte) {
                            'm' => {
                                // SGR sequence - process styling
                                const sgr_params = if (params_slice.len > 0) params_slice else "0";
                                try self.processSgrSequence(sgr_params);
                            },
                            'H', 'f' => {
                                // CUP (Cursor Position) - CSI row;col H
                                self.processCursorPosition(params_slice);
                            },
                            'J' => {
                                // ED (Erase in Display)
                                self.processEraseDisplay(params_slice);
                            },
                            'K' => {
                                // EL (Erase in Line)
                                self.processEraseLine(params_slice);
                            },
                            'G' => {
                                // CHA (Cursor Horizontal Absolute)
                                self.processCursorColumn(params_slice);
                            },
                            'A' => {
                                // CUU (Cursor Up)
                                self.processCursorUp(params_slice);
                            },
                            'B' => {
                                // CUD (Cursor Down)
                                self.processCursorDown(params_slice);
                            },
                            'C' => {
                                // CUF (Cursor Forward/Right)
                                self.processCursorForward(params_slice);
                            },
                            'D' => {
                                // CUB (Cursor Back/Left)
                                self.processCursorBack(params_slice);
                            },
                            'h', 'l' => {
                                // Private mode set/reset (CSI ? Ps h/l)
                                if (params_slice.len > 0 and params_slice[0] == '?') {
                                    self.processPrivateMode(params_slice[1..], byte == 'h');
                                }
                            },
                            else => {},
                        }
                        state = .normal;
                    } else if (byte >= 0x30 and byte <= 0x3f) {
                        // Parameter bytes (0-9, :, ;, <, =, >, ?)
                        try param_buffer.append(self.allocator, byte);
                    }
                    // Intermediate bytes (0x20-0x2f) are collected but not used yet
                },
                .osc => {
                    // Feed byte to OSC parser (returns void; errors reported via osc_end)
                    ghostty.osc_next(self.osc_parser, byte);

                    if (byte == 0x07 or byte == 0x1b) { // BEL or ESC (for ST)
                        // Check if this is ST (ESC \)
                        const is_st = (byte == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\');

                        if (byte == 0x07 or is_st) {
                            const terminator: u8 = if (is_st) 0x9c else byte;
                            const command = ghostty.osc_end(self.osc_parser, terminator);
                            try self.processOscCommand(command);
                            state = .normal;
                        }
                    }
                },
            }
        }
    }

    /// Add a single character to the framebuffer at the current cursor position
    fn addChar(self: *TerminalRuntime, char: u8) !void {
        // Handle control characters
        switch (char) {
            '\r' => {
                // Carriage return
                self.cursor_col = 0;
                return;
            },
            '\n' => {
                // Line feed - move to next line AND reset column (LF implies CR in most terminals)
                self.cursor_col = 0;
                self.cursor_row += 1;
                if (self.cursor_row >= self.rows) {
                    try self.scrollUp();
                    self.cursor_row = self.rows - 1;
                }
                return;
            },
            '\t' => {
                // Tab: advance to next 8-column boundary
                self.cursor_col = @min(((self.cursor_col / 8) + 1) * 8, self.cols - 1);
                return;
            },
            0x08 => { // Backspace
                if (self.cursor_col > 0) {
                    self.cursor_col -= 1;
                }
                return;
            },
            else => {
                // Ignore other control characters (< 0x20)
                if (char < 0x20) return;
            },
        }

        // Ensure we have a valid cursor position
        if (self.cursor_row >= self.framebuffer.items.len) {
            return error.CursorOutOfBounds;
        }

        var row = &self.framebuffer.items[self.cursor_row];

        // Ensure row has enough cells
        while (row.items.len <= self.cursor_col) {
            try row.append(self.allocator, Cell{});
        }

        // Write cell with current style
        row.items[self.cursor_col] = Cell{
            .char = char,
            .fg_color = self.current_style.fg_color,
            .bg_color = self.current_style.bg_color,
            .bold = self.current_style.bold,
            .faint = self.current_style.faint,
            .italic = self.current_style.italic,
            .underline = self.current_style.underline,
            .inverse = self.current_style.inverse,
            .strikethrough = self.current_style.strikethrough,
            .blink = self.current_style.blink,
        };

        // Advance cursor
        self.cursor_col += 1;
        if (self.cursor_col >= self.cols) {
            // Wrap to next line
            self.cursor_col = 0;
            self.cursor_row += 1;
            if (self.cursor_row >= self.rows) {
                try self.scrollUp();
                self.cursor_row = self.rows - 1;
            }
        }
    }

    /// Process CSI H (CUP - Cursor Position)
    fn processCursorPosition(self: *TerminalRuntime, params: []const u8) void {
        var row: usize = 1;
        var col: usize = 1;

        if (params.len > 0) {
            var iter = std.mem.splitScalar(u8, params, ';');
            if (iter.next()) |row_str| {
                if (row_str.len > 0) {
                    row = std.fmt.parseInt(usize, row_str, 10) catch 1;
                }
            }
            if (iter.next()) |col_str| {
                if (col_str.len > 0) {
                    col = std.fmt.parseInt(usize, col_str, 10) catch 1;
                }
            }
        }

        // Convert to 0-indexed and clamp
        self.cursor_row = if (row > 0) @min(row - 1, self.rows - 1) else 0;
        self.cursor_col = if (col > 0) @min(col - 1, self.cols - 1) else 0;
    }

    /// Process CSI G (CHA - Cursor Horizontal Absolute)
    fn processCursorColumn(self: *TerminalRuntime, params: []const u8) void {
        var col: usize = 1;

        if (params.len > 0) {
            col = std.fmt.parseInt(usize, params, 10) catch 1;
        }

        // Convert to 0-indexed and clamp
        self.cursor_col = if (col > 0) @min(col - 1, self.cols - 1) else 0;
    }

    /// Process CSI A (CUU - Cursor Up)
    fn processCursorUp(self: *TerminalRuntime, params: []const u8) void {
        var n: u16 = 1;
        if (params.len > 0) {
            n = std.fmt.parseInt(u16, params, 10) catch 1;
        }
        if (n == 0) n = 1;

        if (self.cursor_row >= n) {
            self.cursor_row -= n;
        } else {
            self.cursor_row = 0;
        }
    }

    /// Process CSI B (CUD - Cursor Down)
    fn processCursorDown(self: *TerminalRuntime, params: []const u8) void {
        var n: u16 = 1;
        if (params.len > 0) {
            n = std.fmt.parseInt(u16, params, 10) catch 1;
        }
        if (n == 0) n = 1;

        const new_row = self.cursor_row + n;
        self.cursor_row = @min(new_row, self.rows - 1);
    }

    /// Process CSI C (CUF - Cursor Forward/Right)
    fn processCursorForward(self: *TerminalRuntime, params: []const u8) void {
        var n: u16 = 1;
        if (params.len > 0) {
            n = std.fmt.parseInt(u16, params, 10) catch 1;
        }
        if (n == 0) n = 1;

        const new_col = self.cursor_col + n;
        self.cursor_col = @min(new_col, self.cols - 1);
    }

    /// Process CSI D (CUB - Cursor Back/Left)
    fn processCursorBack(self: *TerminalRuntime, params: []const u8) void {
        var n: u16 = 1;
        if (params.len > 0) {
            n = std.fmt.parseInt(u16, params, 10) catch 1;
        }
        if (n == 0) n = 1;

        if (self.cursor_col >= n) {
            self.cursor_col -= n;
        } else {
            self.cursor_col = 0;
        }
    }

    /// Process CSI J (ED - Erase in Display)
    fn processEraseDisplay(self: *TerminalRuntime, params: []const u8) void {
        const mode: u8 = if (params.len > 0)
            std.fmt.parseInt(u8, params, 10) catch 0
        else
            0;

        switch (mode) {
            0 => self.clearFromCursorToEndOfScreen(),
            1 => self.clearFromStartOfScreenToCursor(),
            2, 3 => self.clearEntireScreen(),
            else => {},
        }
    }

    /// Process CSI K (EL - Erase in Line)
    fn processEraseLine(self: *TerminalRuntime, params: []const u8) void {
        const mode: u8 = if (params.len > 0)
            std.fmt.parseInt(u8, params, 10) catch 0
        else
            0;

        switch (mode) {
            0 => self.clearFromCursorToEndOfLine(),
            1 => self.clearFromStartOfLineToCursor(),
            2 => self.clearLine(self.cursor_row),
            else => {},
        }
    }

    /// Clear from cursor to end of screen
    fn clearFromCursorToEndOfScreen(self: *TerminalRuntime) void {
        self.clearFromCursorToEndOfLine();
        var row = self.cursor_row + 1;
        while (row < self.rows) : (row += 1) {
            self.clearLine(row);
        }
    }

    /// Clear from start of screen to cursor
    fn clearFromStartOfScreenToCursor(self: *TerminalRuntime) void {
        var row: usize = 0;
        while (row < self.cursor_row) : (row += 1) {
            self.clearLine(row);
        }
        self.clearFromStartOfLineToCursor();
    }

    /// Clear entire screen
    fn clearEntireScreen(self: *TerminalRuntime) void {
        var row: usize = 0;
        while (row < self.rows) : (row += 1) {
            self.clearLine(row);
        }
    }

    /// Clear a specific line
    fn clearLine(self: *TerminalRuntime, row: usize) void {
        if (row >= self.framebuffer.items.len) return;
        const row_cells = &self.framebuffer.items[row];
        for (row_cells.items) |*cell| {
            cell.* = Cell{};
        }
    }

    /// Clear from cursor to end of current line
    fn clearFromCursorToEndOfLine(self: *TerminalRuntime) void {
        if (self.cursor_row >= self.framebuffer.items.len) return;
        const row = &self.framebuffer.items[self.cursor_row];
        var col = self.cursor_col;
        while (col < row.items.len) : (col += 1) {
            row.items[col] = Cell{};
        }
    }

    /// Clear from start of line to cursor
    fn clearFromStartOfLineToCursor(self: *TerminalRuntime) void {
        if (self.cursor_row >= self.framebuffer.items.len) return;
        const row = &self.framebuffer.items[self.cursor_row];
        var col: usize = 0;
        while (col <= self.cursor_col and col < row.items.len) : (col += 1) {
            row.items[col] = Cell{};
        }
    }

    /// Process CSI private mode sequences (CSI ? Ps h/l)
    fn processPrivateMode(self: *TerminalRuntime, params: []const u8, set: bool) void {
        const mode = std.fmt.parseInt(u16, params, 10) catch return;

        switch (mode) {
            47, 1049 => {
                // 47: Alternate screen buffer (legacy)
                // 1049: Alternate screen buffer with save/restore cursor
                if (set) {
                    self.switchToAlternateScreen();
                } else {
                    self.switchToMainScreen();
                }
            },
            else => {},
        }
    }

    /// Switch to alternate screen buffer (saves main screen)
    pub fn switchToAlternateScreen(self: *TerminalRuntime) void {
        if (self.is_alternate_screen) return;

        // Save current framebuffer as alternate (swap semantics)
        self.alternate_framebuffer = self.framebuffer;
        self.is_alternate_screen = true;

        // Create fresh framebuffer for alternate screen
        self.framebuffer = std.ArrayList(std.ArrayList(Cell)){};
        for (0..self.rows) |_| {
            var row = std.ArrayList(Cell).initCapacity(self.allocator, self.cols) catch return;
            row.appendNTimesAssumeCapacity(Cell{}, self.cols);
            self.framebuffer.append(self.allocator, row) catch {
                row.deinit(self.allocator);
                return;
            };
        }

        // Reset cursor position for alternate screen
        self.cursor_row = 0;
        self.cursor_col = 0;

        std.log.debug("Switched to alternate screen buffer", .{});
    }

    /// Switch back to main screen buffer (restores saved screen)
    pub fn switchToMainScreen(self: *TerminalRuntime) void {
        if (!self.is_alternate_screen) return;

        // Clean up current (alternate) framebuffer
        for (self.framebuffer.items) |*row| {
            row.deinit(self.allocator);
        }
        self.framebuffer.deinit(self.allocator);

        // Restore main framebuffer
        if (self.alternate_framebuffer) |saved| {
            self.framebuffer = saved;
            self.alternate_framebuffer = null;
        }

        self.is_alternate_screen = false;

        // Clamp cursor to screen bounds
        if (self.cursor_row >= self.rows) {
            self.cursor_row = if (self.rows > 0) self.rows - 1 else 0;
        }
        if (self.cursor_col >= self.cols) {
            self.cursor_col = if (self.cols > 0) self.cols - 1 else 0;
        }

        std.log.debug("Switched to main screen buffer", .{});
    }

    /// Scroll the framebuffer up by one line, moving top row to scrollback
    fn scrollUp(self: *TerminalRuntime) !void {
        if (self.framebuffer.items.len > 0) {
            var first_row = self.framebuffer.orderedRemove(0);

            // Add to scrollback if within depth limit
            if (self.scrollback.items.len < self.params.scrollback_depth) {
                try self.scrollback.append(self.allocator, first_row);
            } else if (self.params.scrollback_depth > 0) {
                // Scrollback is full - remove oldest line and add new one
                var oldest = self.scrollback.orderedRemove(0);
                oldest.deinit(self.allocator);
                try self.scrollback.append(self.allocator, first_row);
            } else {
                // No scrollback configured - just discard the row
                first_row.deinit(self.allocator);
            }

            // Add new empty row at bottom
            var new_row = std.ArrayList(Cell).initCapacity(self.allocator, self.cols) catch |err| {
                return err;
            };
            new_row.appendNTimesAssumeCapacity(Cell{}, self.cols);
            try self.framebuffer.append(self.allocator, new_row);
        }
    }

    /// Process an SGR sequence and update current styling
    fn processSgrSequence(self: *TerminalRuntime, param_str: []const u8) !void {
        // Parse semicolon-separated parameters
        var params: [16]u16 = undefined;
        var param_count: usize = 0;

        var iter = std.mem.splitScalar(u8, param_str, ';');
        while (iter.next()) |param| : (param_count += 1) {
            if (param_count >= params.len) break;

            if (param.len == 0) {
                params[param_count] = 0; // Empty param means 0
            } else {
                params[param_count] = std.fmt.parseInt(u16, param, 10) catch 0;
            }
        }

        // If no params, default to reset
        if (param_count == 0) {
            params[0] = 0;
            param_count = 1;
        }

        // Feed to SGR parser
        const result = ghostty.sgr_set_params(
            self.sgr_parser,
            &params,
            null,
            param_count,
        );

        if (!ghostty.isSuccess(result)) {
            std.log.warn("SGR parse failed: {s}", .{ghostty.resultMessage(result)});
            return;
        }

        // Extract attributes and update current_style
        var attr: ghostty.SgrAttribute = undefined;
        while (ghostty.sgr_next(self.sgr_parser, &attr)) {
            switch (attr.tag) {
                ghostty.SGR_ATTR_BOLD => {
                    self.current_style.bold = true;
                },
                ghostty.SGR_ATTR_RESET_BOLD => {
                    self.current_style.bold = false;
                },
                ghostty.SGR_ATTR_FAINT => {
                    self.current_style.faint = true;
                },
                ghostty.SGR_ATTR_ITALIC => {
                    self.current_style.italic = true;
                },
                ghostty.SGR_ATTR_RESET_ITALIC => {
                    self.current_style.italic = false;
                },
                ghostty.SGR_ATTR_UNDERLINE => {
                    self.current_style.underline = attr.value.underline;
                },
                ghostty.SGR_ATTR_RESET_UNDERLINE => {
                    self.current_style.underline = ghostty.SGR_UNDERLINE_NONE;
                },
                ghostty.SGR_ATTR_INVERSE => {
                    self.current_style.inverse = true;
                },
                ghostty.SGR_ATTR_RESET_INVERSE => {
                    self.current_style.inverse = false;
                },
                ghostty.SGR_ATTR_STRIKETHROUGH => {
                    self.current_style.strikethrough = true;
                },
                ghostty.SGR_ATTR_RESET_STRIKETHROUGH => {
                    self.current_style.strikethrough = false;
                },
                ghostty.SGR_ATTR_BLINK => {
                    self.current_style.blink = true;
                },
                ghostty.SGR_ATTR_RESET_BLINK => {
                    self.current_style.blink = false;
                },
                ghostty.SGR_ATTR_FG_8 => {
                    self.current_style.fg_color = .{ .indexed = attr.value.fg_8 };
                },
                ghostty.SGR_ATTR_BG_8 => {
                    self.current_style.bg_color = .{ .indexed = attr.value.bg_8 };
                },
                ghostty.SGR_ATTR_FG_256 => {
                    self.current_style.fg_color = .{ .indexed = attr.value.fg_256 };
                },
                ghostty.SGR_ATTR_BG_256 => {
                    self.current_style.bg_color = .{ .indexed = attr.value.bg_256 };
                },
                ghostty.SGR_ATTR_DIRECT_COLOR_FG => {
                    const rgb = attr.value.direct_color_fg;
                    self.current_style.fg_color = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } };
                },
                ghostty.SGR_ATTR_DIRECT_COLOR_BG => {
                    const rgb = attr.value.direct_color_bg;
                    self.current_style.bg_color = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } };
                },
                ghostty.SGR_ATTR_UNSET => {
                    // Reset all styling (SGR 0)
                    self.current_style = Cell{};
                },
                else => {
                    // Log unknown attributes for observability
                    std.log.debug("Unknown SGR attribute: {}", .{attr.tag});
                },
            }
        }
    }

    /// Process a complete OSC command and add it to the event queue
    /// This will be called by feedBytes in Phase 2 when OSC sequences are detected
    fn processOscCommand(self: *TerminalRuntime, command: ghostty.OscCommand) !void {
        const cmd_type = ghostty.osc_command_type(command);

        if (cmd_type == ghostty.OSC_COMMAND_INVALID) {
            std.log.debug("OSC parse error: invalid or unsupported OSC sequence", .{});
            return;
        }

        // Extract command-specific data for policy evaluation
        var payload: ?[]const u8 = null;

        switch (cmd_type) {
            ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE => {
                var title_ptr: [*c]const u8 = undefined;
                const success = ghostty.osc_command_data(
                    command,
                    ghostty.OSC_DATA_CHANGE_WINDOW_TITLE_STR,
                    @ptrCast(&title_ptr),
                );

                if (success and title_ptr != null) {
                    const title = std.mem.span(title_ptr);
                    payload = title;
                }
            },
            ghostty.OSC_COMMAND_PROMPT_START => {
                std.log.debug("OSC 133;A - Prompt Start marker received", .{});
            },
            ghostty.OSC_COMMAND_PROMPT_END => {
                std.log.debug("OSC 133;B - Prompt End marker received", .{});
            },
            ghostty.OSC_COMMAND_END_OF_INPUT => {
                std.log.debug("OSC 133;C - End of Input marker received", .{});
            },
            ghostty.OSC_COMMAND_END_OF_COMMAND => {
                std.log.debug("OSC 133;D - End of Command marker received", .{});
            },
            else => {},
        }

        // Evaluate policy
        var decision = try self.policy_engine.evaluateOsc(cmd_type, payload);
        defer decision.deinit(self.allocator);

        // Only record events that aren't rejected
        const allowed = decision.verdict != .reject;

        if (allowed) {
            var event = OscEvent{
                .command_type = cmd_type,
                .allowed = decision.verdict == .allow,
                .needs_confirmation = decision.verdict == .confirm,
                .rationale = try self.allocator.dupe(u8, decision.rationale),
            };

            // Duplicate payload if we have one
            if (payload) |p| {
                event.payload = try self.allocator.dupe(u8, p);
            }

            try self.osc_events.append(self.allocator, event);
            std.log.info("OSC event: type={}, verdict={s}, rationale={s}", .{
                cmd_type,
                @tagName(decision.verdict),
                decision.rationale,
            });
        } else {
            std.log.warn("OSC command rejected: type={}, rationale={s}", .{
                cmd_type,
                decision.rationale,
            });
        }
    }

    /// Inject a key event into the terminal
    /// Returns an owned slice that the caller must free
    pub fn injectKey(
        self: *TerminalRuntime,
        action: ghostty.KeyAction,
        key: c_uint,
        mods: ghostty.KeyMods,
    ) ![]const u8 {
        // Create key event
        var event: ghostty.KeyEvent = undefined;
        const event_result = ghostty.key_event_new(self.params.allocator, &event);

        if (!ghostty.isSuccess(event_result)) {
            return error.KeyEventCreationFailed;
        }
        defer ghostty.key_event_free(event);

        // Set event properties
        ghostty.key_event_set_action(event, action);
        ghostty.key_event_set_key(event, key);
        ghostty.key_event_set_mods(event, mods);

        // Encode the key event with auto-growing buffer
        return try self.encodeKeyEvent(event);
    }

    /// Encode a key event with automatic buffer growth
    /// Starts with 128 bytes and doubles on OUT_OF_MEMORY
    fn encodeKeyEvent(self: *TerminalRuntime, event: ghostty.KeyEvent) ![]const u8 {
        var buffer_size: usize = 128;
        const max_size: usize = 4096; // Safety limit

        while (buffer_size <= max_size) {
            const buffer = try self.allocator.alloc(u8, buffer_size);
            errdefer self.allocator.free(buffer);

            var written: usize = 0;
            const encode_result = ghostty.key_encoder_encode(
                self.key_encoder,
                event,
                buffer.ptr,
                buffer.len,
                &written,
            );

            if (ghostty.isSuccess(encode_result)) {
                // Success! Shrink buffer to actual size and return
                if (written < buffer_size) {
                    const result = try self.allocator.realloc(buffer, written);
                    return result;
                }
                return buffer;
            }

            // Free the buffer before retrying
            self.allocator.free(buffer);

            if (encode_result == ghostty.OUT_OF_MEMORY) {
                // Double buffer size and retry
                std.log.debug("Key encode buffer too small ({any}), doubling to {any}", .{ buffer_size, buffer_size * 2 });
                buffer_size *= 2;
                continue;
            }

            // Other error, fail
            std.log.err("Key encoding failed: {s}", .{ghostty.resultMessage(encode_result)});
            return error.KeyEncodingFailed;
        }

        // Hit max size without success
        return error.KeyEncodingBufferExhausted;
    }

    /// Enqueue a paste buffer (will be validated before injection)
    /// Returns the encoded paste sequence ready for PTY injection and the policy decision
    pub fn enqueuePaste(self: *TerminalRuntime, text: []const u8) !PasteResult {
        // Check if paste is safe using libghostty
        const is_safe = ghostty.paste_is_safe(text.ptr, text.len);

        // Evaluate with policy engine
        var decision = try self.policy_engine.evaluatePaste(text, is_safe);
        defer decision.deinit(self.allocator);

        std.log.info("Paste policy: {} bytes, verdict: {s}, rationale: {s}", .{
            text.len,
            @tagName(decision.verdict),
            decision.rationale,
        });

        // Only wrap and return if not rejected
        if (decision.verdict == .reject) {
            return PasteResult{
                .bytes = null,
                .verdict = .rejected,
                .rationale = try self.allocator.dupe(u8, decision.rationale),
            };
        }

        const result = try self.wrapBracketedPaste(text);
        const verdict: PasteVerdict = if (decision.verdict == .allow) .safe_auto else .unsafe_needs_confirm;

        return PasteResult{
            .bytes = result,
            .verdict = verdict,
            .rationale = try self.allocator.dupe(u8, decision.rationale),
        };
    }

    /// Wrap text in bracketed paste delimiters
    /// Returns: ESC[200~ + text + ESC[201~
    fn wrapBracketedPaste(self: *TerminalRuntime, text: []const u8) ![]const u8 {
        const start = "\x1b[200~";
        const end = "\x1b[201~";

        const total_len = start.len + text.len + end.len;
        var buffer = try self.allocator.alloc(u8, total_len);

        @memcpy(buffer[0..start.len], start);
        @memcpy(buffer[start.len .. start.len + text.len], text);
        @memcpy(buffer[start.len + text.len ..], end);

        return buffer;
    }

    /// Drain OSC events since last call
    /// Caller is responsible for calling deinit() on each event
    pub fn drainOsc(self: *TerminalRuntime) []OscEvent {
        const events = self.osc_events.toOwnedSlice() catch &[_]OscEvent{};
        return events;
    }

    /// Get current policy statistics
    pub fn getPolicyStats(self: *const TerminalRuntime) policy.PolicyStats {
        return self.policy_engine.getStats();
    }

    /// Create an immutable snapshot of current terminal state
    pub fn snapshot(self: *TerminalRuntime, options: SnapshotOptions) !Snapshot {
        // Copy framebuffer
        var fb_copy = try self.allocator.alloc([]Cell, self.framebuffer.items.len);
        errdefer {
            for (fb_copy, 0..) |row, i| {
                if (i < fb_copy.len) self.allocator.free(row);
            }
            self.allocator.free(fb_copy);
        }

        for (self.framebuffer.items, 0..) |row, i| {
            fb_copy[i] = try self.allocator.dupe(Cell, row.items);
        }

        // Copy scrollback (if requested)
        var sb_copy: [][]Cell = &[_][]Cell{};
        if (options.include_scrollback and self.scrollback.items.len > 0) {
            // Copy last N lines of scrollback (most recent)
            const sb_len = self.scrollback.items.len;
            const lines_to_copy = @min(sb_len, options.scrollback_lines);
            const start_idx = sb_len - lines_to_copy;

            sb_copy = try self.allocator.alloc([]Cell, lines_to_copy);
            errdefer {
                for (sb_copy, 0..) |row, i| {
                    if (i < sb_copy.len) self.allocator.free(row);
                }
                self.allocator.free(sb_copy);
            }

            for (self.scrollback.items[start_idx..], 0..) |row, i| {
                sb_copy[i] = try self.allocator.dupe(Cell, row.items);
            }
        }

        // Copy OSC events
        const osc_copy = try self.allocator.dupe(OscEvent, self.osc_events.items);
        errdefer self.allocator.free(osc_copy);

        // Compute hash
        const hash = computeHash(fb_copy, self.cursor_row, self.cursor_col);

        return Snapshot{
            .hash = hash,
            .timestamp = std.time.milliTimestamp(),
            .rows = self.rows,
            .cols = self.cols,
            .framebuffer = fb_copy,
            .scrollback = sb_copy,
            .cursor_row = self.cursor_row,
            .cursor_col = self.cursor_col,
            .cursor_visible = self.cursor_visible,
            .cursor_style = self.cursor_style,
            .cursor_blinking = self.cursor_blinking,
            .osc_events = osc_copy,
        };
    }

    /// Compute hash of terminal state for snapshot comparison
    fn computeHash(framebuffer: []const []const Cell, cursor_row: u16, cursor_col: u16) u64 {
        var hasher = std.hash.Wyhash.init(0);

        for (framebuffer) |row| {
            for (row) |cell| {
                hasher.update(&[_]u8{cell.char});
                hashColor(&hasher, cell.fg_color);
                hashColor(&hasher, cell.bg_color);
                hasher.update(&[_]u8{@intFromBool(cell.bold)});
                hasher.update(&[_]u8{@intFromBool(cell.faint)});
                hasher.update(&[_]u8{@intFromBool(cell.italic)});
                // underline is c_uint, truncate to u8 for hashing
                const underline_val: u8 = @truncate(cell.underline);
                hasher.update(&[_]u8{underline_val});
                hasher.update(&[_]u8{@intFromBool(cell.inverse)});
                hasher.update(&[_]u8{@intFromBool(cell.strikethrough)});
                hasher.update(&[_]u8{@intFromBool(cell.blink)});
            }
        }

        hasher.update(std.mem.asBytes(&cursor_row));
        hasher.update(std.mem.asBytes(&cursor_col));

        return hasher.final();
    }

    /// Hash a Color value
    fn hashColor(hasher: *std.hash.Wyhash, color: Color) void {
        switch (color) {
            .none => hasher.update(&[_]u8{0}),
            .indexed => |i| {
                hasher.update(&[_]u8{1});
                hasher.update(&[_]u8{i});
            },
            .rgb => |c| {
                hasher.update(&[_]u8{2});
                hasher.update(&[_]u8{ c.r, c.g, c.b });
            },
        }
    }
};

/// OSC event from the terminal
pub const OscEvent = struct {
    /// The type of OSC command
    command_type: ghostty.OscCommandType,

    /// Optional payload data (owned by the event)
    payload: ?[]u8 = null,

    /// Policy decision: whether this event is allowed automatically
    allowed: bool = true,

    /// Whether this event needs user confirmation
    needs_confirmation: bool = false,

    /// Policy rationale (owned by the event)
    rationale: ?[]u8 = null,

    /// Free owned memory
    pub fn deinit(self: *OscEvent, allocator: std.mem.Allocator) void {
        if (self.payload) |p| {
            allocator.free(p);
            self.payload = null;
        }
        if (self.rationale) |r| {
            allocator.free(r);
            self.rationale = null;
        }
    }
};

/// Options for creating a snapshot
pub const SnapshotOptions = struct {
    include_scrollback: bool = true,
    scrollback_lines: u32 = 100,
};

/// Immutable snapshot of terminal state
pub const Snapshot = struct {
    hash: u64,
    timestamp: i64,
    rows: u16,
    cols: u16,

    /// Viewport content (current visible screen)
    framebuffer: []const []const Cell,

    /// Scrollback content (lines that have scrolled off top, oldest first)
    scrollback: []const []const Cell,

    /// Cursor position
    cursor_row: u16,
    cursor_col: u16,

    /// Cursor visibility and style
    cursor_visible: bool,
    cursor_style: CursorStyle,
    cursor_blinking: bool,

    /// Recent OSC events
    osc_events: []const OscEvent,

    /// Free snapshot memory
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.framebuffer) |row| {
            allocator.free(row);
        }
        allocator.free(self.framebuffer);
        for (self.scrollback) |row| {
            allocator.free(row);
        }
        allocator.free(self.scrollback);
        allocator.free(self.osc_events);
    }
};

/// Format a terminal snapshot for LLM context
pub fn formatSnapshotForPrompt(allocator: std.mem.Allocator, snapshot: *const Snapshot) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    // Header with dimensions
    try buf.appendSlice(allocator, "Terminal State (");
    try std.fmt.format(buf.writer(allocator), "{}x{}):\n", .{ snapshot.cols, snapshot.rows });

    // Cursor position
    try std.fmt.format(buf.writer(allocator), "Cursor: row {}, col {}\n", .{
        snapshot.cursor_row, snapshot.cursor_col,
    });

    // Extract non-empty lines (last N, max 10)
    var line_count: usize = 0;
    const max_lines: usize = 10;

    // Find non-empty rows from the end (last N lines)
    var non_empty_indices = std.ArrayList(usize){};
    defer non_empty_indices.deinit(allocator);

    for (snapshot.framebuffer, 0..) |row, idx| {
        var has_content = false;
        for (row) |cell| {
            if (cell.char != ' ' and cell.char != 0) {
                has_content = true;
                break;
            }
        }
        if (has_content) {
            try non_empty_indices.append(allocator, idx);
        }
    }

    // Take the last max_lines non-empty lines
    const start_idx = if (non_empty_indices.items.len > max_lines)
        non_empty_indices.items.len - max_lines
    else
        0;

    for (non_empty_indices.items[start_idx..]) |row_idx| {
        if (line_count >= max_lines) break;

        const row = snapshot.framebuffer[row_idx];
        try buf.appendSlice(allocator, "  | ");
        for (row) |cell| {
            if (cell.char != 0) {
                try buf.append(allocator, cell.char);
            }
        }
        // Trim trailing spaces
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
            _ = buf.pop();
        }
        try buf.append(allocator, '\n');
        line_count += 1;
    }

    // Include safe OSC events (filter out sensitive ones)
    if (snapshot.osc_events.len > 0) {
        var has_safe_events = false;
        for (snapshot.osc_events) |event| {
            const name = getOscEventName(event.command_type);
            if (name != null) {
                if (!has_safe_events) {
                    try buf.appendSlice(allocator, "\nRecent Shell Events:\n");
                    has_safe_events = true;
                }
                try std.fmt.format(buf.writer(allocator), "  - {s}\n", .{name.?});
            }
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Get human-readable name for safe OSC events, returns null for sensitive ones
fn getOscEventName(command_type: ghostty.OscCommandType) ?[]const u8 {
    return switch (command_type) {
        ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE => "Title Change",
        ghostty.OSC_COMMAND_CHANGE_WINDOW_ICON => "Icon Change",
        ghostty.OSC_COMMAND_REPORT_PWD => "Directory Change",
        ghostty.OSC_COMMAND_PROMPT_START => "Prompt Start",
        ghostty.OSC_COMMAND_PROMPT_END => "Prompt End",
        ghostty.OSC_COMMAND_END_OF_INPUT => "End of Input",
        ghostty.OSC_COMMAND_END_OF_COMMAND => "End of Command",
        // Skip sensitive events (clipboard, notifications, etc.)
        ghostty.OSC_COMMAND_CLIPBOARD_CONTENTS => null,
        else => null,
    };
}

// Unit tests
test "terminal runtime initialization" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer runtime.shutdown();

    try testing.expectEqual(@as(u16, 80), runtime.cols);
    try testing.expectEqual(@as(u16, 24), runtime.rows);
}

test "terminal runtime resize" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    try runtime.resize(120, 40);
    try testing.expectEqual(@as(u16, 120), runtime.cols);
    try testing.expectEqual(@as(u16, 40), runtime.rows);
}

test "sgr parser - bold and red foreground" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Parse "bold, red foreground" sequence: ESC[1;31m
    const params = [_]u16{ 1, 31 };
    const result = ghostty.sgr_set_params(
        runtime.sgr_parser,
        &params,
        null,
        params.len,
    );
    try testing.expect(ghostty.isSuccess(result));

    // Iterate through attributes
    var attr: ghostty.SgrAttribute = undefined;
    var found_bold = false;
    var found_red = false;

    while (ghostty.sgr_next(runtime.sgr_parser, &attr)) {
        switch (attr.tag) {
            ghostty.SGR_ATTR_BOLD => {
                found_bold = true;
            },
            ghostty.SGR_ATTR_FG_8 => {
                found_red = true;
                try testing.expectEqual(@as(u8, 1), attr.value.fg_8); // Red = 1
            },
            else => {},
        }
    }

    try testing.expect(found_bold);
    try testing.expect(found_red);
}

test "sgr parser - blink attribute" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Parse "slow blink" sequence: ESC[5m
    const params = [_]u16{5};
    const result = ghostty.sgr_set_params(
        runtime.sgr_parser,
        &params,
        null,
        params.len,
    );
    try testing.expect(ghostty.isSuccess(result));

    var attr: ghostty.SgrAttribute = undefined;
    var found_blink = false;

    while (ghostty.sgr_next(runtime.sgr_parser, &attr)) {
        if (attr.tag == ghostty.SGR_ATTR_BLINK) {
            found_blink = true;
        }
    }

    try testing.expect(found_blink);

    // Test reset blink: ESC[25m
    const reset_params = [_]u16{25};
    const reset_result = ghostty.sgr_set_params(
        runtime.sgr_parser,
        &reset_params,
        null,
        reset_params.len,
    );
    try testing.expect(ghostty.isSuccess(reset_result));

    var found_reset_blink = false;
    while (ghostty.sgr_next(runtime.sgr_parser, &attr)) {
        if (attr.tag == ghostty.SGR_ATTR_RESET_BLINK) {
            found_reset_blink = true;
        }
    }

    try testing.expect(found_reset_blink);
}

test "osc parser - window title change" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Parse OSC 2 (change window title): ESC]2;Test Title\x07
    const osc_bytes = "2;Test Title";

    // Feed bytes to OSC parser
    for (osc_bytes) |byte| {
        ghostty.osc_next(runtime.osc_parser, byte);
    }

    // Finalize with BEL terminator (0x07)
    const command = ghostty.osc_end(runtime.osc_parser, 0x07);
    const cmd_type = ghostty.osc_command_type(command);

    try testing.expectEqual(@as(ghostty.OscCommandType, ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE), cmd_type);

    // Extract title data
    var title_ptr: [*c]const u8 = undefined;
    const data_result = ghostty.osc_command_data(
        command,
        ghostty.OSC_DATA_CHANGE_WINDOW_TITLE_STR,
        @ptrCast(&title_ptr),
    );

    try testing.expect(data_result);
    const title = std.mem.span(title_ptr);
    try testing.expectEqualStrings("Test Title", title);
}

test "paste safety - safe single line text" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    const safe_text = "echo hello world";
    var result = try runtime.enqueuePaste(safe_text);
    defer result.deinit(testing.allocator);

    // Should be marked as safe
    try testing.expectEqual(PasteVerdict.safe_auto, result.verdict);

    // Should be wrapped in bracketed paste
    const expected_start = "\x1b[200~echo hello world\x1b[201~";
    try testing.expectEqualStrings(expected_start, result.bytes.?);
}

test "paste safety - unsafe multiline text with newlines" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    const unsafe_text = "rm -rf /\nsudo reboot";
    var result = try runtime.enqueuePaste(unsafe_text);
    defer result.deinit(testing.allocator);

    // Should be marked as unsafe and need confirmation
    try testing.expectEqual(PasteVerdict.unsafe_needs_confirm, result.verdict);

    // Still wrapped in bracketed paste (execution policy separate)
    try testing.expect(std.mem.startsWith(u8, result.bytes.?, "\x1b[200~"));
    try testing.expect(std.mem.endsWith(u8, result.bytes.?, "\x1b[201~"));
}

test "paste safety - empty text" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    const empty_text = "";
    var result = try runtime.enqueuePaste(empty_text);
    defer result.deinit(testing.allocator);

    // Empty text should be safe
    try testing.expectEqual(PasteVerdict.safe_auto, result.verdict);

    // Should only have bracketed paste markers
    try testing.expectEqualStrings("\x1b[200~\x1b[201~", result.bytes.?);
}

test "paste safety - text with special characters" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    const special_text = "echo 'test $VAR'";
    var result = try runtime.enqueuePaste(special_text);
    defer result.deinit(testing.allocator);

    // Should properly wrap text preserving special chars
    try testing.expect(std.mem.indexOf(u8, result.bytes.?, "echo 'test $VAR'") != null);
}

test "key encoder - basic key press" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Inject a simple 'a' key press
    const encoded = try runtime.injectKey(
        ghostty.KEY_ACTION_PRESS,
        'a',
        0,
    );
    defer testing.allocator.free(encoded);

    // Should produce some output
    try testing.expect(encoded.len > 0);
}

test "key encoder - key with modifiers" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Inject Ctrl+C
    const encoded = try runtime.injectKey(
        ghostty.KEY_ACTION_PRESS,
        'c',
        ghostty.MODS_CTRL,
    );
    defer testing.allocator.free(encoded);

    // Ctrl+C may have no encoding (traditional ASCII 0x03 is sent directly, not encoded)
    // This test just verifies the encoding doesn't crash. Length can be 0 or > 0.
    std.debug.print("Ctrl+C encoded to {} bytes\n", .{encoded.len});
}

test "key encoder configuration - alt esc prefix" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Configure Alt to use ESC prefix
    runtime.setKeyEncoderOptions(.{
        .alt_esc_prefix = true,
    });

    // Inject Alt+A
    const encoded = try runtime.injectKey(
        ghostty.KEY_ACTION_PRESS,
        'a',
        ghostty.MODS_ALT,
    );
    defer testing.allocator.free(encoded);

    // Should produce some output
    try testing.expect(encoded.len > 0);
}

test "key encoder configuration - cursor key application mode" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Enable cursor key application mode
    runtime.setKeyEncoderOptions(.{
        .cursor_key_application = true,
    });

    // This test just validates the option can be set without error
    // Actual encoding differences would require specific cursor key codes
    try testing.expect(true);
}

test "feedBytes - plain text" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    try runtime.feedBytes("Hello World");

    // Check framebuffer content
    try testing.expectEqual(@as(u8, 'H'), runtime.framebuffer.items[0].items[0].char);
    try testing.expectEqual(@as(u8, 'e'), runtime.framebuffer.items[0].items[1].char);
    try testing.expectEqual(@as(u8, 'l'), runtime.framebuffer.items[0].items[2].char);
    try testing.expectEqual(@as(u8, 'l'), runtime.framebuffer.items[0].items[3].char);
    try testing.expectEqual(@as(u8, 'o'), runtime.framebuffer.items[0].items[4].char);

    // Check cursor position (should be after "Hello World")
    try testing.expectEqual(@as(u16, 0), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 11), runtime.cursor_col);
}

test "feedBytes - newlines and cursor control" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    try runtime.feedBytes("Line1\nLine2\r\nLine3");

    // Check first line
    try testing.expectEqual(@as(u8, 'L'), runtime.framebuffer.items[0].items[0].char);
    try testing.expectEqual(@as(u8, 'i'), runtime.framebuffer.items[0].items[1].char);

    // Check second line
    try testing.expectEqual(@as(u8, 'L'), runtime.framebuffer.items[1].items[0].char);
    try testing.expectEqual(@as(u8, 'i'), runtime.framebuffer.items[1].items[1].char);

    // Check third line
    try testing.expectEqual(@as(u8, 'L'), runtime.framebuffer.items[2].items[0].char);

    // Cursor should be on line 2, after "Line3"
    try testing.expectEqual(@as(u16, 2), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 5), runtime.cursor_col);
}

test "feedBytes - SGR bold and color" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Bold red text, then reset
    try runtime.feedBytes("\x1b[1;31mRED\x1b[0mNormal");

    // Check that "RED" has bold and color
    try testing.expect(runtime.framebuffer.items[0].items[0].bold);
    try testing.expect(runtime.framebuffer.items[0].items[0].fg_color.eql(.{ .indexed = 1 })); // Red
    try testing.expectEqual(@as(u8, 'R'), runtime.framebuffer.items[0].items[0].char);

    try testing.expect(runtime.framebuffer.items[0].items[1].bold);
    try testing.expect(runtime.framebuffer.items[0].items[1].fg_color.eql(.{ .indexed = 1 }));

    try testing.expect(runtime.framebuffer.items[0].items[2].bold);
    try testing.expect(runtime.framebuffer.items[0].items[2].fg_color.eql(.{ .indexed = 1 }));

    // Check that "Normal" doesn't have bold or color (reset)
    try testing.expect(!runtime.framebuffer.items[0].items[3].bold);
    try testing.expect(runtime.framebuffer.items[0].items[3].fg_color.eql(.none));
}

test "feedBytes - OSC window title" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Send OSC 2 (change window title)
    try runtime.feedBytes("\x1b]2;Test Window Title\x07");

    // Check that OSC event was captured
    try testing.expectEqual(@as(usize, 1), runtime.osc_events.items.len);
    try testing.expectEqual(@as(c_uint, ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE), runtime.osc_events.items[0].command_type);
}

test "feedBytes - snapshot with content" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    try runtime.feedBytes("Test\nContent");

    var snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);

    // Check snapshot has correct dimensions
    try testing.expectEqual(@as(u16, 24), snap.rows); // Default rows
    try testing.expectEqual(@as(u16, 80), snap.cols); // Default cols

    // Check cursor position
    try testing.expectEqual(@as(u16, 1), snap.cursor_row);
    try testing.expectEqual(@as(u16, 7), snap.cursor_col);

    // Check hash is non-zero (content exists)
    try testing.expect(snap.hash != 0);

    // Check framebuffer content
    try testing.expectEqual(@as(u8, 'T'), snap.framebuffer[0][0].char);
    try testing.expectEqual(@as(u8, 'C'), snap.framebuffer[1][0].char);
}

test "feedBytes - snapshot hash changes with content" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // First snapshot - empty
    var snap1 = try runtime.snapshot(.{});
    defer snap1.deinit(testing.allocator);
    const hash1 = snap1.hash;

    // Add content
    try runtime.feedBytes("Changed");

    // Second snapshot - with content
    var snap2 = try runtime.snapshot(.{});
    defer snap2.deinit(testing.allocator);
    const hash2 = snap2.hash;

    // Hashes should be different
    try testing.expect(hash1 != hash2);
}

test "cursor style and visibility" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Check default cursor state
    try testing.expect(runtime.cursor_visible);
    try testing.expectEqual(CursorStyle.block, runtime.cursor_style);
    try testing.expect(runtime.cursor_blinking);

    // Modify cursor state
    runtime.cursor_visible = false;
    runtime.cursor_style = .bar;
    runtime.cursor_blinking = false;

    // Verify changes persist in snapshot
    var snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);

    try testing.expect(!snap.cursor_visible);
    try testing.expectEqual(CursorStyle.bar, snap.cursor_style);
    try testing.expect(!snap.cursor_blinking);
}

test "reset - clears terminal state" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Add content and move cursor
    try runtime.feedBytes("Hello\x1b[1;31mWorld");

    // Verify state is non-default
    try testing.expectEqual(@as(u8, 'H'), runtime.framebuffer.items[0].items[0].char);
    try testing.expect(runtime.cursor_col > 0);
    try testing.expect(runtime.current_style.bold);

    // Add an OSC event
    try runtime.feedBytes("\x1b]2;Test Title\x07");
    try testing.expectEqual(@as(usize, 1), runtime.osc_events.items.len);

    // Reset the terminal
    try runtime.reset();

    // Verify framebuffer is cleared
    try testing.expectEqual(@as(u8, ' '), runtime.framebuffer.items[0].items[0].char);

    // Verify cursor is at origin
    try testing.expectEqual(@as(u16, 0), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);

    // Verify style is reset
    try testing.expect(!runtime.current_style.bold);
    try testing.expect(runtime.current_style.fg_color.eql(.none));

    // Verify OSC events are cleared
    try testing.expectEqual(@as(usize, 0), runtime.osc_events.items.len);
}

test "formatSnapshotForPrompt - basic formatting" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{
        .cols = 40,
        .rows = 10,
    });
    defer runtime.shutdown();

    // Add some content
    try runtime.feedBytes("Hello World");

    // Take snapshot
    var snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);

    // Format for prompt
    const formatted = try formatSnapshotForPrompt(testing.allocator, &snap);
    defer testing.allocator.free(formatted);

    // Check header is present
    try testing.expect(std.mem.indexOf(u8, formatted, "Terminal State (40x10):") != null);

    // Check cursor position is present
    try testing.expect(std.mem.indexOf(u8, formatted, "Cursor: row 0, col 11") != null);

    // Check content line is present
    try testing.expect(std.mem.indexOf(u8, formatted, "  | Hello World") != null);
}

test "formatSnapshotForPrompt - with OSC events" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Add OSC title change event
    try runtime.feedBytes("\x1b]2;My Terminal\x07");

    // Take snapshot
    var snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);

    // Format for prompt
    const formatted = try formatSnapshotForPrompt(testing.allocator, &snap);
    defer testing.allocator.free(formatted);

    // Check OSC events section is present
    try testing.expect(std.mem.indexOf(u8, formatted, "Recent Shell Events:") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "  - Title Change") != null);
}

test "formatSnapshotForPrompt - max lines limit" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{
        .cols = 40,
        .rows = 20,
    });
    defer runtime.shutdown();

    // Add more than 10 lines of content
    for (0..15) |_| {
        try runtime.feedBytes("Line X\n");
    }

    // Take snapshot
    var snap = try runtime.snapshot(.{});
    defer snap.deinit(testing.allocator);

    // Format for prompt
    const formatted = try formatSnapshotForPrompt(testing.allocator, &snap);
    defer testing.allocator.free(formatted);

    // Count lines starting with "  | " (should be max 10)
    var line_count: usize = 0;
    var iter = std.mem.splitSequence(u8, formatted, "\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "  | ")) {
            line_count += 1;
        }
    }
    try testing.expect(line_count <= 10);
}

test "CSI H cursor position" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer runtime.shutdown();

    try runtime.feedBytes("\x1b[5;10H"); // Move to row 5, col 10
    try testing.expectEqual(@as(u16, 4), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 9), runtime.cursor_col);

    try runtime.feedBytes("\x1b[H"); // Move to home (1,1)
    try testing.expectEqual(@as(u16, 0), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);

    // Test with only row specified
    try runtime.feedBytes("\x1b[3H");
    try testing.expectEqual(@as(u16, 2), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);

    // Test clamping to bounds
    try runtime.feedBytes("\x1b[100;100H");
    try testing.expectEqual(@as(u16, 23), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 79), runtime.cursor_col);
}

test "CSI J erase display" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer runtime.shutdown();

    try runtime.feedBytes("Line1\nLine2\nLine3");
    try runtime.feedBytes("\x1b[2J"); // Clear screen

    // First cell should be empty (space with default char)
    try testing.expectEqual(@as(u8, ' '), runtime.framebuffer.items[0].items[0].char);
}

test "CSI K erase line" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 20, .rows = 3 });
    defer runtime.shutdown();

    try runtime.feedBytes("HelloWorld");
    // Cursor is now at col 10. Move to col 6 (1-indexed = index 5)
    try runtime.feedBytes("\x1b[6G");
    try testing.expectEqual(@as(u16, 5), runtime.cursor_col);
    try runtime.feedBytes("\x1b[K"); // Erase from cursor to end

    // First 5 chars should remain (cols 0-4: "Hello")
    try testing.expectEqual(@as(u8, 'H'), runtime.framebuffer.items[0].items[0].char);
    try testing.expectEqual(@as(u8, 'e'), runtime.framebuffer.items[0].items[1].char);
    try testing.expectEqual(@as(u8, 'l'), runtime.framebuffer.items[0].items[2].char);
    try testing.expectEqual(@as(u8, 'l'), runtime.framebuffer.items[0].items[3].char);
    try testing.expectEqual(@as(u8, 'o'), runtime.framebuffer.items[0].items[4].char);
    // Col 5 onwards should be cleared
    try testing.expectEqual(@as(u8, ' '), runtime.framebuffer.items[0].items[5].char);
    try testing.expectEqual(@as(u8, ' '), runtime.framebuffer.items[0].items[6].char);
}

test "CSI G cursor horizontal absolute" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer runtime.shutdown();

    try runtime.feedBytes("Hello");
    try runtime.feedBytes("\x1b[1G"); // Move to col 1 (first column)
    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);

    try runtime.feedBytes("\x1b[10G"); // Move to col 10
    try testing.expectEqual(@as(u16, 9), runtime.cursor_col);
}

test "CSI A cursor up" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer runtime.shutdown();

    // Move to row 10
    try runtime.feedBytes("\x1b[10;1H");
    try testing.expectEqual(@as(u16, 9), runtime.cursor_row);

    // Move up 3 rows
    try runtime.feedBytes("\x1b[3A");
    try testing.expectEqual(@as(u16, 6), runtime.cursor_row);

    // Default is 1
    try runtime.feedBytes("\x1b[A");
    try testing.expectEqual(@as(u16, 5), runtime.cursor_row);

    // Clamp at top
    try runtime.feedBytes("\x1b[100A");
    try testing.expectEqual(@as(u16, 0), runtime.cursor_row);
}

test "CSI B cursor down" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer runtime.shutdown();

    try testing.expectEqual(@as(u16, 0), runtime.cursor_row);

    // Move down 5 rows
    try runtime.feedBytes("\x1b[5B");
    try testing.expectEqual(@as(u16, 5), runtime.cursor_row);

    // Default is 1
    try runtime.feedBytes("\x1b[B");
    try testing.expectEqual(@as(u16, 6), runtime.cursor_row);

    // Clamp at bottom
    try runtime.feedBytes("\x1b[100B");
    try testing.expectEqual(@as(u16, 23), runtime.cursor_row);
}

test "CSI C cursor forward" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer runtime.shutdown();

    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);

    // Move forward 10 columns
    try runtime.feedBytes("\x1b[10C");
    try testing.expectEqual(@as(u16, 10), runtime.cursor_col);

    // Default is 1
    try runtime.feedBytes("\x1b[C");
    try testing.expectEqual(@as(u16, 11), runtime.cursor_col);

    // Clamp at right
    try runtime.feedBytes("\x1b[100C");
    try testing.expectEqual(@as(u16, 79), runtime.cursor_col);
}

test "CSI D cursor back" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer runtime.shutdown();

    // Start at column 20
    try runtime.feedBytes("\x1b[20G");
    try testing.expectEqual(@as(u16, 19), runtime.cursor_col);

    // Move back 5 columns
    try runtime.feedBytes("\x1b[5D");
    try testing.expectEqual(@as(u16, 14), runtime.cursor_col);

    // Default is 1
    try runtime.feedBytes("\x1b[D");
    try testing.expectEqual(@as(u16, 13), runtime.cursor_col);

    // Clamp at left
    try runtime.feedBytes("\x1b[100D");
    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);
}

test "SGR faint, inverse, strikethrough" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{});
    defer runtime.shutdown();

    // Test faint (code 2)
    try runtime.feedBytes("\x1b[2mF");
    try testing.expect(runtime.framebuffer.items[0].items[0].faint);

    // Test inverse (code 7)
    try runtime.feedBytes("\x1b[7mI");
    try testing.expect(runtime.framebuffer.items[0].items[1].inverse);
    try testing.expect(runtime.framebuffer.items[0].items[1].faint); // Still faint

    // Test strikethrough (code 9)
    try runtime.feedBytes("\x1b[9mS");
    try testing.expect(runtime.framebuffer.items[0].items[2].strikethrough);

    // Reset all
    try runtime.feedBytes("\x1b[0mN");
    try testing.expect(!runtime.framebuffer.items[0].items[3].faint);
    try testing.expect(!runtime.framebuffer.items[0].items[3].inverse);
    try testing.expect(!runtime.framebuffer.items[0].items[3].strikethrough);
}

test "alternate screen buffer switching" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer runtime.shutdown();

    // Write content to main screen
    try runtime.feedBytes("Main Screen");
    try testing.expectEqual(@as(u8, 'M'), runtime.framebuffer.items[0].items[0].char);
    try testing.expect(!runtime.is_alternate_screen);

    // Switch to alternate screen via CSI ?1049h
    try runtime.feedBytes("\x1b[?1049h");
    try testing.expect(runtime.is_alternate_screen);

    // Alternate screen should be blank
    try testing.expectEqual(@as(u8, ' '), runtime.framebuffer.items[0].items[0].char);
    try testing.expectEqual(@as(u16, 0), runtime.cursor_row);
    try testing.expectEqual(@as(u16, 0), runtime.cursor_col);

    // Write to alternate screen
    try runtime.feedBytes("Alt Screen");
    try testing.expectEqual(@as(u8, 'A'), runtime.framebuffer.items[0].items[0].char);

    // Switch back to main screen via CSI ?1049l
    try runtime.feedBytes("\x1b[?1049l");
    try testing.expect(!runtime.is_alternate_screen);

    // Main screen content should be restored
    try testing.expectEqual(@as(u8, 'M'), runtime.framebuffer.items[0].items[0].char);
    try testing.expectEqual(@as(u8, 'a'), runtime.framebuffer.items[0].items[1].char);
}

test "alternate screen buffer - legacy mode 47" {
    const testing = std.testing;

    var runtime = try TerminalRuntime.init(testing.allocator, .{ .cols = 20, .rows = 5 });
    defer runtime.shutdown();

    try runtime.feedBytes("Original");
    try runtime.feedBytes("\x1b[?47h");
    try testing.expect(runtime.is_alternate_screen);

    try runtime.feedBytes("\x1b[?47l");
    try testing.expect(!runtime.is_alternate_screen);
    try testing.expectEqual(@as(u8, 'O'), runtime.framebuffer.items[0].items[0].char);
}
