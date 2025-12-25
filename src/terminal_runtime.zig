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
    fg_color: ?u8 = null,
    bg_color: ?u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: ghostty.SgrUnderline = 0, // GHOSTTY_SGR_UNDERLINE_NONE
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

    /// Current cursor position
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,

    /// Current styling attributes (applied to new characters)
    current_style: Cell = .{},

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
        };
        errdefer runtime.osc_events.deinit(allocator);

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
        _ = self; // TODO: Use self when implementing
        // TODO: Implement full reset logic
        // - Flush SGR/OSC parsers
        // - Clear scrollback
        // - Zero key encoder state
        // - Recreate snapshots

        std.log.info("Terminal runtime reset", .{});
    }

    /// Resize the terminal viewport
    pub fn resize(self: *TerminalRuntime, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;

        // TODO: Trigger libghostty reflow
        // TODO: Emit delta snapshots for providers

        std.log.info("Terminal resized to {any}x{any}", .{ cols, rows });
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
                        if (byte == 'm') {
                            // SGR sequence - process styling
                            const params_slice = if (param_buffer.items.len > 0)
                                param_buffer.items
                            else
                                "0"; // Default to reset

                            try self.processSgrSequence(params_slice);
                        }
                        // Other CSI sequences (cursor movement, etc.) ignored for now
                        state = .normal;
                    } else if (byte >= 0x30 and byte <= 0x3f) {
                        // Parameter bytes (0-9, :, ;, <, =, >, ?)
                        try param_buffer.append(self.allocator, byte);
                    }
                    // Intermediate bytes (0x20-0x2f) are collected but not used yet
                },
                .osc => {
                    // Feed byte to OSC parser
                    const result = ghostty.osc_next(self.osc_parser, byte);
                    _ = result; // TODO: Handle parse errors

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
            .italic = self.current_style.italic,
            .underline = self.current_style.underline,
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

    /// Scroll the framebuffer up by one line
    fn scrollUp(self: *TerminalRuntime) !void {
        // Remove first row (it would go into scrollback, but we don't implement that yet)
        if (self.framebuffer.items.len > 0) {
            var first_row = self.framebuffer.orderedRemove(0);
            first_row.deinit(self.allocator);

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
                ghostty.SGR_ATTR_FG_8 => {
                    self.current_style.fg_color = attr.value.fg_8;
                },
                ghostty.SGR_ATTR_BG_8 => {
                    self.current_style.bg_color = attr.value.bg_8;
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
            else => {
                // Other OSC types don't have data extraction implemented yet
                // Will be expanded as libghostty adds more data accessors
            },
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
        _ = options; // TODO: Use for scrollback inclusion

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
            .cursor_row = self.cursor_row,
            .cursor_col = self.cursor_col,
            .osc_events = osc_copy,
        };
    }

    /// Compute hash of terminal state for snapshot comparison
    fn computeHash(framebuffer: []const []const Cell, cursor_row: u16, cursor_col: u16) u64 {
        var hasher = std.hash.Wyhash.init(0);

        for (framebuffer) |row| {
            for (row) |cell| {
                hasher.update(&[_]u8{cell.char});
                if (cell.fg_color) |c| hasher.update(&[_]u8{c});
                if (cell.bg_color) |c| hasher.update(&[_]u8{c});
                hasher.update(&[_]u8{@intFromBool(cell.bold)});
                hasher.update(&[_]u8{@intFromBool(cell.italic)});
                // underline is c_uint, truncate to u8 for hashing
                const underline_val: u8 = @truncate(cell.underline);
                hasher.update(&[_]u8{underline_val});
            }
        }

        hasher.update(std.mem.asBytes(&cursor_row));
        hasher.update(std.mem.asBytes(&cursor_col));

        return hasher.final();
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

    /// Cursor position
    cursor_row: u16,
    cursor_col: u16,

    /// Recent OSC events
    osc_events: []const OscEvent,

    /// Free snapshot memory
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.framebuffer) |row| {
            allocator.free(row);
        }
        allocator.free(self.framebuffer);
        allocator.free(self.osc_events);
    }
};

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
    try testing.expectEqual(@as(?u8, 1), runtime.framebuffer.items[0].items[0].fg_color); // Red
    try testing.expectEqual(@as(u8, 'R'), runtime.framebuffer.items[0].items[0].char);

    try testing.expect(runtime.framebuffer.items[0].items[1].bold);
    try testing.expectEqual(@as(?u8, 1), runtime.framebuffer.items[0].items[1].fg_color);

    try testing.expect(runtime.framebuffer.items[0].items[2].bold);
    try testing.expectEqual(@as(?u8, 1), runtime.framebuffer.items[0].items[2].fg_color);

    // Check that "Normal" doesn't have bold or color (reset)
    try testing.expect(!runtime.framebuffer.items[0].items[3].bold);
    try testing.expectEqual(@as(?u8, null), runtime.framebuffer.items[0].items[3].fg_color);
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
