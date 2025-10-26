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
};

fn anthropicPayload(alloc: std.mem.Allocator, model: []const u8, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","max_tokens":256,"system":"{s}","messages":[{{"role":"user","content":"{s}"}}]}}
    , .{ model, s, u });
}

fn geminiPayload(alloc: std.mem.Allocator, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"contents":[{{"role":"user","parts":[{{"text":"{s}"}}]}}],"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},"generationConfig":{{"temperature":0.3,"maxOutputTokens":256}}}}
    , .{ u, s });
}

fn openaiPayload(alloc: std.mem.Allocator, model: []const u8, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","instructions":"{s}","input":"{s}","max_tokens":256,"temperature":0.3}}
    , .{ model, s, u });
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

pub fn query(
    allocator: std.mem.Allocator,
    cfg: Config,
    query_text: []const u8,
    system_prompt: []const u8,
) ![]u8 {
    if (cfg.provider == .echo) {
        return std.fmt.allocPrint(allocator, "echo '{s}'", .{query_text});
    }

    const resp: http.Response = switch (cfg.provider) {
        .anthropic => blk: {
            if (cfg.anthropic_key == null) return error.MissingApiKey;
            const body = try anthropicPayload(allocator, cfg.anthropic_model, system_prompt, query_text);
            defer allocator.free(body);
            const auth_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{cfg.anthropic_key.?});
            defer allocator.free(auth_header);
            const headers = [_][]const u8{ auth_header, "anthropic-version: 2023-06-01" };
            break :blk try http.postJson(allocator, "https://api.anthropic.com/v1/messages", &headers, body);
        },
        .gemini => blk: {
            if (cfg.gemini_key == null) return error.MissingApiKey;
            const body = try geminiPayload(allocator, system_prompt, query_text);
            defer allocator.free(body);
            const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ cfg.gemini_model, cfg.gemini_key.? });
            defer allocator.free(url);
            break :blk try http.postJson(allocator, url, &.{}, body);
        },
        .openai => blk: {
            if (cfg.openai_key == null) return error.MissingApiKey;
            const body = try openaiPayload(allocator, cfg.openai_model, system_prompt, query_text);
            defer allocator.free(body);
            const header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{cfg.openai_key.?});
            defer allocator.free(header);
            break :blk try http.postJson(allocator, cfg.openai_url, &.{header}, body);
        },
        .ollama => blk: {
            const body = try ollamaPayload(allocator, cfg.ollama_model, system_prompt, query_text);
            defer allocator.free(body);
            const url = try std.fmt.allocPrint(allocator, "{s}/api/generate", .{cfg.ollama_url});
            defer allocator.free(url);
            break :blk try http.postJson(allocator, url, &.{}, body);
        },
        .echo => unreachable,
    };

    defer allocator.free(resp.body);

    const val: ?[]u8 = switch (cfg.provider) {
        .anthropic => extractFirstStringAfter(allocator, resp.body, "text"),
        .gemini => extractFirstStringAfter(allocator, resp.body, "text"),
        .openai => extractFirstStringAfter(allocator, resp.body, "output_text"),
        .ollama => extractFirstStringAfter(allocator, resp.body, "response"),
        .echo => null,
    };

    if (val) |vraw| {
        defer allocator.free(vraw);
        var oneline = try allocator.dupe(u8, vraw);
        const trimmed = trimSingleLineInPlace(oneline);
        // oneline is now trimmed - return it without re-duping
        return oneline[0..trimmed.len];
    }

    // Try to extract error message from error responses
    if (std.mem.indexOf(u8, resp.body, "\"error\"")) |_| {
        return std.fmt.allocPrint(allocator, "API Error: Invalid request or API key", .{});
    }

    return error.BadResponse;
}
