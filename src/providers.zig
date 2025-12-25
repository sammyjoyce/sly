const std = @import("std");
const http = @import("http.zig");

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    // Validate and escape UTF-8 properly
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];

        // Handle single-byte escapes
        switch (ch) {
            '\\' => {
                try out.appendSlice(allocator, "\\\\");
                i += 1;
            },
            '"' => {
                try out.appendSlice(allocator, "\\\"");
                i += 1;
            },
            '\n' => {
                try out.appendSlice(allocator, "\\n");
                i += 1;
            },
            '\r' => {
                try out.appendSlice(allocator, "\\r");
                i += 1;
            },
            '\t' => {
                try out.appendSlice(allocator, "\\t");
                i += 1;
            },
            8 => {
                try out.appendSlice(allocator, "\\b");
                i += 1;
            },
            12 => {
                try out.appendSlice(allocator, "\\f");
                i += 1;
            },
            0...7, 11, 14...31 => {
                // Escape other control characters as \uXXXX
                try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                i += 1;
            },
            else => {
                // Try to decode as UTF-8
                const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    // Invalid UTF-8, escape as hex
                    try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                    i += 1;
                    continue;
                };

                // Ensure we have enough bytes
                if (i + len > s.len) {
                    // Truncated UTF-8 sequence, escape it
                    try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                    i += 1;
                    continue;
                }

                // Validate the sequence
                _ = std.unicode.utf8Decode(s[i..][0..len]) catch {
                    // Invalid UTF-8 sequence, escape first byte
                    try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                    i += 1;
                    continue;
                };

                // Valid UTF-8, copy the whole sequence
                try out.appendSlice(allocator, s[i .. i + len]);
                i += len;
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn unescapeJson(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                't' => try out.append(allocator, '\t'),
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                'b' => try out.append(allocator, 8),
                'f' => try out.append(allocator, 12),
                else => try out.append(allocator, s[i]),
            }
        } else try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

fn extractFirstStringAfter(allocator: std.mem.Allocator, hay: []const u8, key: []const u8) ?[]u8 {
    var pat_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;

    const idx = std.mem.indexOf(u8, hay, pat) orelse return null;
    var i = idx + pat.len;
    const start = i;
    var escaped = false;

    while (i < hay.len) : (i += 1) {
        const ch = hay[i];
        if (!escaped) {
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') {
                const raw = hay[start..i];
                return unescapeJson(allocator, raw) catch null;
            }
        } else {
            escaped = false;
        }
    }
    return null;
}

pub fn trimSingleLineInPlace(s: []u8) []u8 {
    var j: usize = 0;
    for (s) |ch| {
        if (ch != '\n' and ch != '\r') {
            s[j] = ch;
            j += 1;
        }
    }
    const trimmed = std.mem.trimRight(u8, s[0..j], " \t");
    // Return mutable slice so it can be used directly
    return @constCast(trimmed);
}

pub const Provider = enum { anthropic, gemini, openai, ollama, echo };

pub const Config = struct {
    provider: Provider,
    anthropic_key: ?[]const u8 = null,
    anthropic_model: []const u8 = "claude-3-5-sonnet-20241022",

    gemini_key: ?[]const u8 = null,
    gemini_model: []const u8 = "gemini-2.0-flash-exp",

    openai_key: ?[]const u8 = null,
    openai_model: []const u8 = "gpt-4o",
    openai_url: []const u8 = "https://api.openai.com/v1/responses",

    ollama_model: []const u8 = "llama3.2",
    ollama_url: []const u8 = "http://localhost:11434",

    timeout_ms: u32 = 30000,

    /// Maximum tokens for LLM response. Default varies by provider:
    /// - Anthropic: 1024
    /// - Gemini: 256
    /// - OpenAI: 256
    /// - Ollama: 256
    max_tokens: ?u32 = null,

    /// Get max tokens with provider-specific defaults
    pub fn getMaxTokens(self: Config) u32 {
        if (self.max_tokens) |t| return t;
        return switch (self.provider) {
            .anthropic => 1024,
            .gemini, .openai, .ollama => 256,
            .echo => 256,
        };
    }
};

fn anthropicPayload(alloc: std.mem.Allocator, model: []const u8, max_tokens: u32, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","max_tokens":{d},"system":"{s}","messages":[{{"role":"user","content":"{s}"}}]}}
    , .{ model, max_tokens, s, u });
}

fn geminiPayload(alloc: std.mem.Allocator, max_tokens: u32, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"contents":[{{"role":"user","parts":[{{"text":"{s}"}}]}}],"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},"generationConfig":{{"temperature":0.3,"maxOutputTokens":{d}}}}}
    , .{ u, s, max_tokens });
}

fn openaiPayload(alloc: std.mem.Allocator, model: []const u8, max_tokens: u32, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    // OpenAI Responses API payload
    // Use "input" for the user prompt and "instructions" for the system prompt.
    // Responses API uses max_output_tokens instead of max_tokens.
    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","input":"{s}","instructions":"{s}","max_output_tokens":{d},"temperature":0.3}}
    , .{ model, u, s, max_tokens });
}

fn ollamaPayload(alloc: std.mem.Allocator, model: []const u8, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","system":"{s}","stream":false,"options":{{"temperature":0.3}}}}
    , .{ model, u, s });
}

/// Query a provider for a CommandPlan JSON.
/// Returns the CommandPlan JSON string extracted from the provider's response.
/// The caller is responsible for freeing the returned string.
pub fn query(
    allocator: std.mem.Allocator,
    cfg: Config,
    query_text: []const u8,
    system_prompt: []const u8,
) ![]u8 {
    if (cfg.provider == .echo) {
        // Echo provider returns a minimal valid CommandPlan JSON
        const timestamp = std.time.milliTimestamp();
        return std.fmt.allocPrint(allocator,
            \\{{"plan_id":"echo-{d}","command":"echo","args":["{s}"],"env":{{}},"stdin":null,"paste_policy":"auto","confirm_mode":"auto","expectations":[],"failure_signals":[],"created_at":{d}}}
        , .{ timestamp, query_text, timestamp });
    }

    const max_tokens = cfg.getMaxTokens();

    const resp: http.Response = switch (cfg.provider) {
        .anthropic => blk: {
            if (cfg.anthropic_key == null) return error.MissingApiKey;
            const body = try anthropicPayload(allocator, cfg.anthropic_model, max_tokens, system_prompt, query_text);
            defer allocator.free(body);
            const auth_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{cfg.anthropic_key.?});
            defer allocator.free(auth_header);
            const headers = [_][]const u8{ auth_header, "anthropic-version: 2023-06-01" };
            break :blk try http.postJsonWithTimeout(allocator, "https://api.anthropic.com/v1/messages", &headers, body, cfg.timeout_ms);
        },
        .gemini => blk: {
            if (cfg.gemini_key == null) return error.MissingApiKey;
            const body = try geminiPayload(allocator, max_tokens, system_prompt, query_text);
            defer allocator.free(body);
            const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ cfg.gemini_model, cfg.gemini_key.? });
            defer allocator.free(url);
            break :blk try http.postJsonWithTimeout(allocator, url, &.{}, body, cfg.timeout_ms);
        },
        .openai => blk: {
            if (cfg.openai_key == null) return error.MissingApiKey;
            const body = try openaiPayload(allocator, cfg.openai_model, max_tokens, system_prompt, query_text);
            defer allocator.free(body);
            const header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{cfg.openai_key.?});
            defer allocator.free(header);
            break :blk try http.postJsonWithTimeout(allocator, cfg.openai_url, &.{header}, body, cfg.timeout_ms);
        },
        .ollama => blk: {
            const body = try ollamaPayload(allocator, cfg.ollama_model, system_prompt, query_text);
            defer allocator.free(body);
            const url = try std.fmt.allocPrint(allocator, "{s}/api/generate", .{cfg.ollama_url});
            defer allocator.free(url);
            break :blk try http.postJsonWithTimeout(allocator, url, &.{}, body, cfg.timeout_ms);
        },
        .echo => unreachable,
    };

    defer allocator.free(resp.body);

    // Check for rate limiting before processing response
    if (resp.status == 429) {
        return error.TooManyRequests;
    }

    // Extract the text response which should contain CommandPlan JSON
    const val: ?[]u8 = switch (cfg.provider) {
        .anthropic => extractFirstStringAfter(allocator, resp.body, "text"),
        .gemini => extractFirstStringAfter(allocator, resp.body, "text"),
        .openai => extractFirstStringAfter(allocator, resp.body, "output_text"),
        .ollama => extractFirstStringAfter(allocator, resp.body, "response"),
        .echo => null,
    };

    if (val) |plan_json| {
        // The extracted text should be the CommandPlan JSON - return it directly
        // Note: We trim whitespace but keep it as JSON (may be multi-line)
        var trimmed = std.mem.trim(u8, plan_json, " \t\n\r");

        // Strip markdown code fences if present (```json ... ``` or ``` ... ```)
        if (std.mem.startsWith(u8, trimmed, "```json")) {
            trimmed = trimmed[7..]; // Skip "```json"
            trimmed = std.mem.trim(u8, trimmed, " \t\n\r");
        } else if (std.mem.startsWith(u8, trimmed, "```")) {
            trimmed = trimmed[3..]; // Skip "```"
            trimmed = std.mem.trim(u8, trimmed, " \t\n\r");
        }

        if (std.mem.endsWith(u8, trimmed, "```")) {
            trimmed = trimmed[0 .. trimmed.len - 3];
            trimmed = std.mem.trim(u8, trimmed, " \t\n\r");
        }

        const result = try allocator.dupe(u8, trimmed);
        allocator.free(plan_json);
        return result;
    }

    if (extractFirstStringAfter(allocator, resp.body, "message")) |emsg| {
        defer allocator.free(emsg);
        return std.fmt.allocPrint(allocator, "API Error: {s}", .{emsg});
    }

    return error.BadResponse;
}

/// Check if an error is transient (network-related) and worth retrying
fn isTransientError(err: anyerror) bool {
    return switch (err) {
        error.Network,
        error.Unavailable,
        error.BadResponse,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.TooManyRequests,
        => true,
        else => false,
    };
}

/// Query a provider with retry logic and exponential backoff.
/// Returns the CommandPlan JSON string extracted from the provider's response.
/// The caller is responsible for freeing the returned string.
pub fn queryWithRetry(
    allocator: std.mem.Allocator,
    cfg: Config,
    query_text: []const u8,
    system_prompt: []const u8,
    max_retries: u8,
) ![]u8 {
    const base_delay_ms: u64 = 500;
    var attempt: u8 = 0;

    while (true) : (attempt += 1) {
        const result = query(allocator, cfg, query_text, system_prompt);

        if (result) |response| {
            return response;
        } else |err| {
            if (!isTransientError(err) or attempt >= max_retries) {
                return err;
            }

            const delay_ms = base_delay_ms * (@as(u64, 1) << @intCast(attempt));
            std.log.warn("Query attempt {d}/{d} failed with {s}, retrying in {d}ms...", .{
                attempt + 1,
                max_retries + 1,
                @errorName(err),
                delay_ms,
            });

            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
    }
}

test "queryWithRetry compiles and returns on first success" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .provider = .echo,
    };

    const result = try queryWithRetry(allocator, cfg, "test query", "system prompt", 3);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "echo") != null);
}

test "jsonEscape - basic ASCII strings" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "hello world");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello world", result);
}

test "jsonEscape - empty string" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "jsonEscape - quotes and backslashes" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "say \"hello\" and use \\path");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("say \\\"hello\\\" and use \\\\path", result);
}

test "jsonEscape - control characters" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "line1\nline2\ttab\rcarriage");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("line1\\nline2\\ttab\\rcarriage", result);
}

test "jsonEscape - backspace and form feed" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "back\x08space\x0Cform");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("back\\bspace\\fform", result);
}

test "jsonEscape - other control characters as unicode escapes" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "null:\x00bell:\x07");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("null:\\u0000bell:\\u0007", result);
}

test "jsonEscape - invalid UTF-8 sequences" {
    const allocator = std.testing.allocator;

    // Invalid continuation byte (0x80-0xBF not following a lead byte)
    const result1 = try jsonEscape(allocator, "bad\x80byte");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("bad\\u0080byte", result1);

    // Truncated UTF-8 sequence (lead byte without enough continuation bytes)
    const result2 = try jsonEscape(allocator, "trunc\xC2");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("trunc\\u00c2", result2);
}

test "jsonEscape - valid UTF-8 multibyte" {
    const allocator = std.testing.allocator;

    const result = try jsonEscape(allocator, "emoji: 🎉");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("emoji: 🎉", result);
}

test "trimSingleLineInPlace - removes newlines" {
    var buf = [_]u8{ 'h', 'e', 'l', 'l', 'o', '\n', 'w', 'o', 'r', 'l', 'd' };
    const result = trimSingleLineInPlace(&buf);

    try std.testing.expectEqualStrings("helloworld", result);
}

test "trimSingleLineInPlace - removes CRLF" {
    var buf = [_]u8{ 'l', 'i', 'n', 'e', '1', '\r', '\n', 'l', 'i', 'n', 'e', '2' };
    const result = trimSingleLineInPlace(&buf);

    try std.testing.expectEqualStrings("line1line2", result);
}

test "trimSingleLineInPlace - already clean string" {
    var buf = [_]u8{ 'c', 'l', 'e', 'a', 'n' };
    const result = trimSingleLineInPlace(&buf);

    try std.testing.expectEqualStrings("clean", result);
}

test "trimSingleLineInPlace - empty string" {
    var buf = [_]u8{};
    const result = trimSingleLineInPlace(&buf);

    try std.testing.expectEqualStrings("", result);
}

test "trimSingleLineInPlace - trims trailing whitespace" {
    var buf = [_]u8{ 't', 'e', 's', 't', ' ', '\t', ' ' };
    const result = trimSingleLineInPlace(&buf);

    try std.testing.expectEqualStrings("test", result);
}

test "Config.getMaxTokens - default values by provider" {
    const anthropic_cfg = Config{ .provider = .anthropic };
    try std.testing.expectEqual(@as(u32, 1024), anthropic_cfg.getMaxTokens());

    const gemini_cfg = Config{ .provider = .gemini };
    try std.testing.expectEqual(@as(u32, 256), gemini_cfg.getMaxTokens());

    const openai_cfg = Config{ .provider = .openai };
    try std.testing.expectEqual(@as(u32, 256), openai_cfg.getMaxTokens());

    const ollama_cfg = Config{ .provider = .ollama };
    try std.testing.expectEqual(@as(u32, 256), ollama_cfg.getMaxTokens());

    const echo_cfg = Config{ .provider = .echo };
    try std.testing.expectEqual(@as(u32, 256), echo_cfg.getMaxTokens());
}

test "Config.getMaxTokens - custom value overrides default" {
    const cfg = Config{
        .provider = .anthropic,
        .max_tokens = 2048,
    };

    try std.testing.expectEqual(@as(u32, 2048), cfg.getMaxTokens());
}
