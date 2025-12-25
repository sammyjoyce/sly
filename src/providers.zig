/// AI Provider Abstraction Layer - Multi-provider LLM query interface
///
/// This module provides a unified interface for querying multiple AI/LLM providers
/// (Anthropic Claude, Google Gemini, OpenAI, Ollama) to generate CommandPlan JSON
/// responses. The abstraction allows sly to work with any supported provider without
/// changing the core logic.
///
/// ## Supported Providers
///
/// - **Anthropic**: Claude models via the Messages API (requires API key)
/// - **Gemini**: Google's Gemini models via the GenerateContent API (requires API key)
/// - **OpenAI**: GPT models via the Responses API (requires API key)
/// - **Ollama**: Local LLM inference via Ollama's generate API (no key required)
/// - **Echo**: Debug/test provider that echoes back the query as a CommandPlan
///
/// ## Usage
///
/// ```zig
/// const cfg = Config{
///     .provider = .anthropic,
///     .anthropic_key = "sk-...",
///     .max_tokens = 512,
/// };
/// const result = try query(allocator, cfg, "list files", system_prompt);
/// defer allocator.free(result);
/// ```
///
/// ## Error Handling
///
/// The module returns specific errors for different failure modes:
/// - `error.MissingApiKey`: Required API key not provided
/// - `error.BadResponse`: Provider returned unparseable response
/// - `error.TooManyRequests`: Rate limited (HTTP 429)
/// - Network errors are propagated from the http module
///
/// ## Thread Safety
///
/// All functions are thread-safe as they use only stack-local state and
/// the provided allocator. Multiple concurrent queries are supported.
const std = @import("std");
const http = @import("http.zig");

/// Escape a string for safe embedding in JSON.
///
/// Handles all JSON escape sequences including:
/// - Standard escapes: `\\`, `\"`, `\n`, `\r`, `\t`, `\b`, `\f`
/// - Control characters (0x00-0x1F) as `\uXXXX`
/// - Invalid UTF-8 sequences as `\uXXXX` per byte
///
/// This is critical for preventing JSON injection attacks and ensuring
/// valid JSON output regardless of input content.
///
/// Memory: Caller owns the returned slice and must free it.
///
/// Returns `error.OutOfMemory` if allocation fails.
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];

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
                try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                i += 1;
            },
            else => {
                const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                    i += 1;
                    continue;
                };

                if (i + len > s.len) {
                    try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                    i += 1;
                    continue;
                }

                _ = std.unicode.utf8Decode(s[i..][0..len]) catch {
                    try out.writer(allocator).print("\\u{x:0>4}", .{ch});
                    i += 1;
                    continue;
                };

                try out.appendSlice(allocator, s[i .. i + len]);
                i += len;
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Unescape a JSON string value, converting escape sequences back to characters.
///
/// Handles standard JSON escapes: `\n`, `\r`, `\t`, `\"`, `\\`, `\b`, `\f`.
/// Unknown escapes are passed through as-is.
///
/// This is the inverse of `jsonEscape` and is used when parsing JSON string
/// values from provider responses.
///
/// Memory: Caller owns the returned slice and must free it.
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

/// Extract and unescape the first JSON string value for a given key.
///
/// Uses simple pattern matching to find `"key":"value"` in the JSON response.
/// This is a lightweight alternative to full JSON parsing, optimized for
/// extracting single values from known response structures.
///
/// Example: For input `{"text":"hello world"}` and key `"text"`,
/// returns `"hello world"`.
///
/// Memory: Caller owns the returned slice and must free it.
/// Returns null if the key is not found or if unescaping fails.
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

/// Remove newlines from a string in-place and trim trailing whitespace.
///
/// Used to collapse multi-line responses into single-line commands.
/// Operates destructively on the input buffer to avoid allocation.
///
/// Returns a slice of the modified input buffer (may be shorter than original).
pub fn trimSingleLineInPlace(s: []u8) []u8 {
    var j: usize = 0;
    for (s) |ch| {
        if (ch != '\n' and ch != '\r') {
            s[j] = ch;
            j += 1;
        }
    }
    const trimmed = std.mem.trimRight(u8, s[0..j], " \t");
    return @constCast(trimmed);
}

/// Supported AI/LLM providers.
///
/// Each provider has different API requirements, authentication methods,
/// and response formats. The `query()` function handles these differences
/// internally, providing a unified interface.
///
/// - `anthropic`: Anthropic Claude models (cloud, requires API key)
/// - `gemini`: Google Gemini models (cloud, requires API key)
/// - `openai`: OpenAI GPT models (cloud, requires API key)
/// - `ollama`: Local Ollama server (no auth required)
/// - `echo`: Debug provider that echoes queries as valid CommandPlan JSON
pub const Provider = enum { anthropic, gemini, openai, ollama, echo };

/// Configuration for provider selection and authentication.
///
/// Contains all provider-specific settings including API keys, model names,
/// endpoints, and timeout values. Only the settings for the selected provider
/// need to be populated.
///
/// ## Environment Variables
///
/// The CLI typically populates these from environment variables:
/// - `ANTHROPIC_API_KEY` → `anthropic_key`
/// - `GEMINI_API_KEY` → `gemini_key`
/// - `OPENAI_API_KEY` → `openai_key`
/// - `SLY_PROVIDER` → `provider`
///
/// ## Example
///
/// ```zig
/// const cfg = Config{
///     .provider = .anthropic,
///     .anthropic_key = std.posix.getenv("ANTHROPIC_API_KEY"),
///     .anthropic_model = "claude-3-5-sonnet-20241022",
///     .timeout_ms = 30000,
/// };
/// ```
pub const Config = struct {
    /// The AI provider to use for queries.
    provider: Provider,

    /// Anthropic API key (required for .anthropic provider).
    anthropic_key: ?[]const u8 = null,
    /// Anthropic model identifier. Default: claude-3-5-sonnet-20241022.
    anthropic_model: []const u8 = "claude-3-5-sonnet-20241022",

    /// Google Gemini API key (required for .gemini provider).
    gemini_key: ?[]const u8 = null,
    /// Gemini model identifier. Default: gemini-2.0-flash-exp.
    gemini_model: []const u8 = "gemini-2.0-flash-exp",

    /// OpenAI API key (required for .openai provider).
    openai_key: ?[]const u8 = null,
    /// OpenAI model identifier. Default: gpt-4o.
    openai_model: []const u8 = "gpt-4o",
    /// OpenAI API endpoint URL. Default: https://api.openai.com/v1/responses.
    openai_url: []const u8 = "https://api.openai.com/v1/responses",

    /// Ollama model identifier. Default: llama3.2.
    ollama_model: []const u8 = "llama3.2",
    /// Ollama server URL. Default: http://localhost:11434.
    ollama_url: []const u8 = "http://localhost:11434",

    /// HTTP request timeout in milliseconds. Default: 30000 (30 seconds).
    timeout_ms: u32 = 30000,

    /// Maximum tokens for LLM response. If null, uses provider-specific defaults:
    /// - Anthropic: 1024
    /// - Gemini: 256
    /// - OpenAI: 256
    /// - Ollama: 256
    max_tokens: ?u32 = null,

    /// Get max tokens with provider-specific defaults.
    ///
    /// Returns the configured `max_tokens` if set, otherwise returns the
    /// default value for the selected provider.
    pub fn getMaxTokens(self: Config) u32 {
        if (self.max_tokens) |t| return t;
        return switch (self.provider) {
            .anthropic => 1024,
            .gemini, .openai, .ollama => 256,
            .echo => 256,
        };
    }
};

/// Build the JSON request payload for Anthropic's Messages API.
///
/// Creates a properly formatted request body with:
/// - Model identifier
/// - Max tokens limit
/// - System prompt (as top-level "system" field)
/// - User message in the messages array
///
/// Memory: Caller owns the returned slice and must free it.
fn anthropicPayload(alloc: std.mem.Allocator, model: []const u8, max_tokens: u32, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","max_tokens":{d},"system":"{s}","messages":[{{"role":"user","content":"{s}"}}]}}
    , .{ model, max_tokens, s, u });
}

/// Build the JSON request payload for Google Gemini's GenerateContent API.
///
/// Creates a properly formatted request body with:
/// - User content in the contents array
/// - System instruction as a separate field
/// - Generation config with temperature and maxOutputTokens
///
/// Memory: Caller owns the returned slice and must free it.
fn geminiPayload(alloc: std.mem.Allocator, max_tokens: u32, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"contents":[{{"role":"user","parts":[{{"text":"{s}"}}]}}],"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},"generationConfig":{{"temperature":0.3,"maxOutputTokens":{d}}}}}
    , .{ u, s, max_tokens });
}

/// Build the JSON request payload for OpenAI's Responses API.
///
/// Creates a properly formatted request body with:
/// - Model identifier
/// - User input (as "input" field, not "messages")
/// - System instructions (as "instructions" field)
/// - max_output_tokens (Responses API uses this instead of max_tokens)
/// - Temperature for response variability
///
/// Note: This uses the Responses API format, not the Chat Completions API.
///
/// Memory: Caller owns the returned slice and must free it.
fn openaiPayload(alloc: std.mem.Allocator, model: []const u8, max_tokens: u32, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","input":"{s}","instructions":"{s}","max_output_tokens":{d},"temperature":0.3}}
    , .{ model, u, s, max_tokens });
}

/// Build the JSON request payload for Ollama's generate API.
///
/// Creates a properly formatted request body with:
/// - Model identifier
/// - User prompt
/// - System prompt
/// - Stream disabled (we want the complete response)
/// - Temperature option for response variability
///
/// Memory: Caller owns the returned slice and must free it.
fn ollamaPayload(alloc: std.mem.Allocator, model: []const u8, sys: []const u8, user: []const u8) ![]u8 {
    const s = try jsonEscape(alloc, sys);
    defer alloc.free(s);
    const u = try jsonEscape(alloc, user);
    defer alloc.free(u);

    return std.fmt.allocPrint(alloc,
        \\{{"model":"{s}","prompt":"{s}","system":"{s}","stream":false,"options":{{"temperature":0.3}}}}
    , .{ model, u, s });
}

/// Query the configured AI provider for a CommandPlan JSON response.
///
/// This is the main entry point for AI queries. It handles all provider-specific
/// details including authentication, payload formatting, and response parsing.
///
/// ## Parameters
///
/// - `allocator`: Memory allocator for response and intermediate allocations
/// - `cfg`: Provider configuration (see `Config` struct)
/// - `query_text`: The natural language query from the user
/// - `system_prompt`: Instructions for the AI (CommandPlan schema, context, etc.)
///
/// ## Returns
///
/// The CommandPlan JSON string extracted from the provider's response.
/// The caller is responsible for freeing the returned string.
///
/// ## Errors
///
/// - `error.MissingApiKey`: API key required but not provided
/// - `error.BadResponse`: Could not parse provider response
/// - `error.TooManyRequests`: Provider rate limit exceeded (HTTP 429)
/// - Network errors from the http module
///
/// ## Example
///
/// ```zig
/// const plan_json = try query(allocator, cfg, "list files", system_prompt);
/// defer allocator.free(plan_json);
/// const plan = try CommandPlan.parse(allocator, plan_json);
/// ```
pub fn query(
    allocator: std.mem.Allocator,
    cfg: Config,
    query_text: []const u8,
    system_prompt: []const u8,
) ![]u8 {
    if (cfg.provider == .echo) {
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

    if (resp.status == 429) {
        return error.TooManyRequests;
    }

    const val: ?[]u8 = switch (cfg.provider) {
        .anthropic => extractFirstStringAfter(allocator, resp.body, "text"),
        .gemini => extractFirstStringAfter(allocator, resp.body, "text"),
        .openai => extractFirstStringAfter(allocator, resp.body, "output_text"),
        .ollama => extractFirstStringAfter(allocator, resp.body, "response"),
        .echo => null,
    };

    if (val) |plan_json| {
        var trimmed = std.mem.trim(u8, plan_json, " \t\n\r");

        // Strip markdown code fences if present (```json ... ``` or ``` ... ```)
        if (std.mem.startsWith(u8, trimmed, "```json")) {
            trimmed = trimmed[7..];
            trimmed = std.mem.trim(u8, trimmed, " \t\n\r");
        } else if (std.mem.startsWith(u8, trimmed, "```")) {
            trimmed = trimmed[3..];
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

/// Check if an error is transient (network-related) and worth retrying.
///
/// Used by `queryWithRetry()` to determine whether to attempt another request
/// after a failure. Transient errors are typically temporary network issues
/// or server-side rate limiting that may resolve on retry.
///
/// Returns true for:
/// - Network connectivity errors
/// - Connection refused/reset/timeout
/// - DNS failures
/// - Rate limiting (HTTP 429)
/// - Bad/incomplete responses
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

/// Query a provider with automatic retry and exponential backoff.
///
/// Wraps `query()` with retry logic for transient errors. Uses exponential
/// backoff starting at 500ms and doubling each attempt (500ms, 1s, 2s, 4s...).
///
/// ## Parameters
///
/// - `allocator`: Memory allocator for response and intermediate allocations
/// - `cfg`: Provider configuration (see `Config` struct)
/// - `query_text`: The natural language query from the user
/// - `system_prompt`: Instructions for the AI
/// - `max_retries`: Maximum number of retry attempts (0 = no retries)
///
/// ## Returns
///
/// The CommandPlan JSON string on success.
/// The caller is responsible for freeing the returned string.
///
/// ## Errors
///
/// Returns the last error encountered after all retries are exhausted,
/// or immediately for non-transient errors (e.g., `error.MissingApiKey`).
///
/// ## Example
///
/// ```zig
/// // Try up to 4 times total (1 initial + 3 retries)
/// const plan_json = try queryWithRetry(allocator, cfg, "list files", prompt, 3);
/// defer allocator.free(plan_json);
/// ```
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
