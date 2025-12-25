# LLM Integration Specification

## Overview

sly uses Large Language Models to convert natural language queries into shell commands. This document specifies the provider abstraction, CommandPlan schema, prompt engineering, and integration patterns.

## Provider Architecture

### Provider Abstraction

```zig
pub const Provider = enum {
    anthropic,  // Claude
    gemini,     // Google Gemini
    openai,     // GPT
    ollama,     // Local models
    echo,       // Offline testing
};

pub const Config = struct {
    provider: Provider,

    // Anthropic
    anthropic_key: ?[]const u8,
    anthropic_model: []const u8,

    // Gemini
    gemini_key: ?[]const u8,
    gemini_model: []const u8,

    // OpenAI
    openai_key: ?[]const u8,
    openai_model: []const u8,
    openai_url: []const u8,

    // Ollama
    ollama_model: []const u8,
    ollama_url: []const u8,
};
```

### Provider Selection

```zig
pub fn autoDetectProvider(allocator: Allocator) Provider {
    // Explicit selection
    if (getEnvOpt(allocator, "SLY_PROVIDER")) |p| {
        defer allocator.free(p);
        return parseProvider(p);
    }

    // Auto-detect from API keys
    if (getEnvOpt(allocator, "ANTHROPIC_API_KEY")) |k| {
        allocator.free(k);
        return .anthropic;
    }
    if (getEnvOpt(allocator, "OPENAI_API_KEY")) |k| {
        allocator.free(k);
        return .openai;
    }
    if (getEnvOpt(allocator, "GEMINI_API_KEY")) |k| {
        allocator.free(k);
        return .gemini;
    }

    // Default to local Ollama
    return .ollama;
}
```

## Provider Implementations

### Anthropic (Claude)

```zig
pub fn queryAnthropic(allocator: Allocator, config: Config, query: []const u8, system: []const u8) ![]u8 {
    const payload = try std.json.stringifyAlloc(allocator, .{
        .model = config.anthropic_model,
        .max_tokens = 1024,
        .system = system,
        .messages = &[_]struct { role: []const u8, content: []const u8 }{
            .{ .role = "user", .content = query },
        },
    }, .{});
    defer allocator.free(payload);

    return http.post(
        allocator,
        "https://api.anthropic.com/v1/messages",
        payload,
        &[_]http.Header{
            .{ .name = "x-api-key", .value = config.anthropic_key.? },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        },
    );
}
```

### OpenAI (GPT)

```zig
pub fn queryOpenai(allocator: Allocator, config: Config, query: []const u8, system: []const u8) ![]u8 {
    const payload = try std.json.stringifyAlloc(allocator, .{
        .model = config.openai_model,
        .input = query,
        .instructions = system,
    }, .{});
    defer allocator.free(payload);

    return http.post(
        allocator,
        config.openai_url,
        payload,
        &[_]http.Header{
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{config.openai_key.?}) },
            .{ .name = "content-type", .value = "application/json" },
        },
    );
}
```

### Google Gemini

```zig
pub fn queryGemini(allocator: Allocator, config: Config, query: []const u8, system: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}",
        .{ config.gemini_model, config.gemini_key.? },
    );
    defer allocator.free(url);

    const payload = try std.json.stringifyAlloc(allocator, .{
        .system_instruction = .{ .parts = &[_]struct { text: []const u8 }{ .{ .text = system } } },
        .contents = &[_]struct { parts: []const struct { text: []const u8 } }{
            .{ .parts = &[_]struct { text: []const u8 }{ .{ .text = query } } },
        },
    }, .{});
    defer allocator.free(payload);

    return http.post(allocator, url, payload, &.{});
}
```

### Ollama (Local)

```zig
pub fn queryOllama(allocator: Allocator, config: Config, query: []const u8, system: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/api/generate", .{config.ollama_url});
    defer allocator.free(url);

    const payload = try std.json.stringifyAlloc(allocator, .{
        .model = config.ollama_model,
        .system = system,
        .prompt = query,
        .stream = false,
    }, .{});
    defer allocator.free(payload);

    return http.post(allocator, url, payload, &.{});
}
```

### Echo (Testing)

```zig
pub fn queryEcho(allocator: Allocator, query: []const u8) ![]u8 {
    // Return a valid CommandPlan JSON for testing
    return std.fmt.allocPrint(allocator,
        \\{{"plan_id":"echo-1","command":"echo","args":["{s}"],"env":{{}},"stdin":null,"paste_policy":"auto","confirm_mode":"auto","expectations":[],"failure_signals":[],"created_at":{d}}}
    , .{ query, std.time.timestamp() });
}
```

## CommandPlan Schema

### JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "CommandPlan",
  "type": "object",
  "required": ["plan_id", "command"],
  "properties": {
    "plan_id": {
      "type": "string",
      "description": "Unique identifier for audit trail"
    },
    "command": {
      "type": "string",
      "description": "Base command without arguments"
    },
    "args": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Command arguments"
    },
    "env": {
      "type": "object",
      "additionalProperties": { "type": "string" },
      "description": "Environment variables"
    },
    "stdin": {
      "type": ["string", "null"],
      "description": "Standard input data"
    },
    "paste_policy": {
      "type": "string",
      "enum": ["auto", "needs_confirm", "never"]
    },
    "confirm_mode": {
      "type": "string",
      "enum": ["auto", "preview", "reject"]
    },
    "expectations": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "pattern": { "type": "string" },
          "exit_code": { "type": "integer" }
        }
      }
    },
    "failure_signals": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["pattern"],
        "properties": {
          "pattern": { "type": "string" },
          "severity": {
            "type": "string",
            "enum": ["warning", "err", "critical"]
          }
        }
      }
    },
    "created_at": {
      "type": "integer",
      "description": "Unix timestamp in milliseconds"
    }
  }
}
```

### Zig Structure

```zig
pub const CommandPlan = struct {
    plan_id: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: std.StringHashMap([]const u8),
    stdin: ?[]const u8 = null,
    paste_policy: PastePolicy = .needs_confirm,
    confirm_mode: ConfirmMode = .preview,
    expectations: []const Expectation = &.{},
    failure_signals: []const FailureSignal = &.{},
    created_at: i64 = 0,

    pub fn fromJson(allocator: Allocator, json_str: []const u8) !CommandPlan;
    pub fn toJson(self: CommandPlan, allocator: Allocator) ![]const u8;
    pub fn deinit(self: *CommandPlan, allocator: Allocator) void;
};
```

## System Prompt

### Base Prompt

```
You are a shell command generator. Generate a CommandPlan JSON schema for executing shell commands based on the user's natural language request.

CRITICAL: Your response must be ONLY the JSON object. Do not include:
- Explanations before or after the JSON
- Markdown code fences (```json or ```)
- Any text outside the JSON object
- Newlines before the opening brace

Start your response with { and end with }

CommandPlan JSON Schema:
{
  "plan_id": "unique-id-string",
  "command": "base-command",
  "args": ["arg1", "arg2"],
  "env": {"VAR": "value"},
  "stdin": "optional stdin data or null",
  "paste_policy": "auto|needs_confirm|never",
  "confirm_mode": "auto|preview|reject",
  "expectations": [{"pattern": "expected output pattern", "exit_code": 0}],
  "failure_signals": [{"pattern": "error pattern", "severity": "warning|err|critical"}],
  "created_at": 0
}
```

### Schema Rules

```
SCHEMA RULES:
1. plan_id: Generate a unique identifier (e.g., "cmd-" + timestamp)
2. command: The base command without arguments (e.g., "echo", "git", "find")
3. args: Array of command arguments (use proper quoting for spaces/special chars)
4. env: Object with environment variables (empty {} if none needed)
5. stdin: String for piped input, or null if not needed
6. paste_policy: "auto" for safe commands, "needs_confirm" for potentially dangerous ones
7. confirm_mode: "auto" for safe execution, "preview" to show before running
8. expectations: Optional array of expected outcomes for validation
9. failure_signals: Optional array of error patterns to detect failures
10. created_at: Unix timestamp (use current time in milliseconds)
```

### Examples in Prompt

```
Examples:

User: "say hello"
{"plan_id":"cmd-1","command":"echo","args":["Hello World!"],"env":{},"stdin":null,"paste_policy":"auto","confirm_mode":"auto","expectations":[],"failure_signals":[],"created_at":1699564800000}

User: "find all text files"
{"plan_id":"cmd-2","command":"find","args":[".","-name","*.txt"],"env":{},"stdin":null,"paste_policy":"auto","confirm_mode":"auto","expectations":[],"failure_signals":[],"created_at":1699564800000}

User: "delete all logs"
{"plan_id":"cmd-3","command":"rm","args":["-rf","*.log"],"env":{},"stdin":null,"paste_policy":"needs_confirm","confirm_mode":"preview","expectations":[],"failure_signals":[{"pattern":"cannot remove","severity":"err"}],"created_at":1699564800000}
```

## Context Building

### Context Sources

```zig
pub fn buildContext(allocator: Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Working directory
    const cwd = try std.process.getCwd(allocator);
    defer allocator.free(cwd);
    try std.fmt.format(buf.writer(), "Working directory: {s}\n", .{cwd});

    // Shell type
    if (getEnvOpt(allocator, "SHELL")) |shell| {
        defer allocator.free(shell);
        try std.fmt.format(buf.writer(), "Shell: {s}\n", .{shell});
    }

    // Git status
    if (try detectGitRepo()) {
        try buf.appendSlice("Git repository: yes\n");
        if (try getGitBranch(allocator)) |branch| {
            defer allocator.free(branch);
            try std.fmt.format(buf.writer(), "Git branch: {s}\n", .{branch});
        }
    }

    // Project type
    if (try detectProjectType(allocator)) |project| {
        defer allocator.free(project);
        try std.fmt.format(buf.writer(), "Project type: {s}\n", .{project});
    }

    return buf.toOwnedSlice();
}
```

### Terminal Snapshot Context

```zig
pub fn formatSnapshotForPrompt(allocator: Allocator, snapshot: *const Snapshot) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);

    // Terminal dimensions
    try std.fmt.format(buf.writer(), "Terminal State ({}x{}):\n", .{
        snapshot.cols, snapshot.rows
    });

    // Cursor position
    try std.fmt.format(buf.writer(), "Cursor Position: row {}, col {}\n", .{
        snapshot.cursor_row, snapshot.cursor_col
    });

    // Recent terminal output (last N non-empty lines)
    var line_count: usize = 0;
    const max_lines = 10;

    for (snapshot.framebuffer) |row| {
        if (line_count >= max_lines) break;

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
                if (cell.char != 0) try buf.append(cell.char);
            }
            try buf.append('\n');
            line_count += 1;
        }
    }

    // Safe OSC events
    if (snapshot.osc_events.len > 0) {
        try buf.appendSlice("\nRecent Shell Events:\n");
        for (snapshot.osc_events) |event| {
            const name = oscEventName(event.command_type) orelse continue;
            try std.fmt.format(buf.writer(), "  - {s}\n", .{name});
        }
    }

    return buf.toOwnedSlice();
}
```

### Full System Prompt Assembly

```zig
pub fn buildSystemPrompt(
    allocator: Allocator,
    context: []const u8,
    extend: ?[]const u8,
    snapshot: ?*const Snapshot,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);

    // Base prompt
    try buf.appendSlice(BASE_PROMPT);

    // User extensions
    if (extend) |e| {
        try buf.appendSlice("\n\n");
        try buf.appendSlice(e);
    }

    // Environment context
    try buf.appendSlice("\n\nContext:\n");
    try buf.appendSlice(context);

    // Terminal snapshot
    if (snapshot) |snap| {
        const snapshot_text = try formatSnapshotForPrompt(allocator, snap);
        defer allocator.free(snapshot_text);
        try buf.appendSlice("\n\n");
        try buf.appendSlice(snapshot_text);
    }

    return buf.toOwnedSlice();
}
```

## Response Parsing

### JSON Extraction

```zig
pub fn extractJsonFromResponse(allocator: Allocator, response: []const u8) ![]const u8 {
    // Find JSON object boundaries
    const start = std.mem.indexOf(u8, response, "{") orelse return error.NoJsonFound;
    const end = std.mem.lastIndexOf(u8, response, "}") orelse return error.NoJsonFound;

    if (end <= start) return error.InvalidJson;

    return allocator.dupe(u8, response[start..end + 1]);
}
```

### CommandPlan Parsing

```zig
pub fn fromJson(allocator: Allocator, json_str: []const u8) !CommandPlan {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;

    // Required fields
    const plan_id = root.get("plan_id") orelse return error.MissingField;
    const command = root.get("command") orelse return error.MissingField;

    // Build plan
    var plan = CommandPlan{
        .plan_id = try allocator.dupe(u8, plan_id.string),
        .command = try allocator.dupe(u8, command.string),
        .env = std.StringHashMap([]const u8).init(allocator),
        .created_at = std.time.timestamp(),
    };

    // Parse optional fields
    if (root.get("args")) |args_arr| {
        var args = std.ArrayList([]const u8).init(allocator);
        for (args_arr.array.items) |arg| {
            try args.append(try allocator.dupe(u8, arg.string));
        }
        plan.args = try args.toOwnedSlice();
    }

    // ... parse other fields

    return plan;
}
```

## Retry Logic

### Generation with Retries

```zig
pub fn generatePlan(
    allocator: Allocator,
    query: []const u8,
    config: Config,
    max_retries: u8,
    snapshot: ?*const Snapshot,
) !CommandPlan {
    var attempt: u8 = 0;
    var last_error: []const u8 = "";

    while (attempt < max_retries) : (attempt += 1) {
        const json_str = try generate(allocator, query, config, snapshot);
        defer allocator.free(json_str);

        log.debug("Attempt {}/{}: Received JSON ({} bytes)", .{
            attempt + 1, max_retries, json_str.len
        });

        if (CommandPlan.fromJson(allocator, json_str)) |plan| {
            log.info("Successfully validated CommandPlan: {s}", .{plan.plan_id});
            return plan;
        } else |err| {
            last_error = switch (err) {
                error.MissingField => "Missing required field",
                error.UnexpectedToken => "Invalid JSON syntax",
                else => "JSON parsing error",
            };
            log.warn("Attempt {}/{}: {s}", .{attempt + 1, max_retries, last_error});
            continue;
        }
    }

    log.err("Failed after {} attempts: {s}", .{max_retries, last_error});
    return error.ValidationFailed;
}
```

### Fallback Behavior

```zig
// On network error, try echo provider
if (config.provider != .echo and (err == error.Network or err == error.Unavailable)) {
    var fallback_cfg = config;
    fallback_cfg.provider = .echo;
    return providers.query(allocator, fallback_cfg, query, prompt);
}
```

## Configuration Validation

### API Key Validation

```zig
pub fn validateConfig(config: Config) !void {
    switch (config.provider) {
        .anthropic => {
            const key = config.anthropic_key orelse {
                log.err("ANTHROPIC_API_KEY not set");
                return error.MissingApiKey;
            };
            if (key.len < 10) {
                log.err("ANTHROPIC_API_KEY appears invalid");
                return error.InvalidApiKey;
            }
        },
        .openai => {
            const key = config.openai_key orelse {
                log.err("OPENAI_API_KEY not set");
                return error.MissingApiKey;
            };
            if (key.len < 10) {
                log.err("OPENAI_API_KEY appears invalid");
                return error.InvalidApiKey;
            }
        },
        .gemini => {
            const key = config.gemini_key orelse {
                log.err("GEMINI_API_KEY not set");
                return error.MissingApiKey;
            };
            if (key.len < 10) {
                log.err("GEMINI_API_KEY appears invalid");
                return error.InvalidApiKey;
            }
        },
        .ollama, .echo => {},
    }
}
```

## Environment Variables

### Provider Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SLY_PROVIDER` | (auto) | Provider: anthropic, gemini, openai, ollama, echo |
| `ANTHROPIC_API_KEY` | - | Anthropic API key |
| `SLY_ANTHROPIC_MODEL` | claude-3-5-sonnet-20241022 | Anthropic model |
| `GEMINI_API_KEY` | - | Google Gemini API key |
| `SLY_GEMINI_MODEL` | gemini-2.0-flash-exp | Gemini model |
| `OPENAI_API_KEY` | - | OpenAI API key |
| `SLY_OPENAI_MODEL` | gpt-4o | OpenAI model |
| `SLY_OPENAI_URL` | https://api.openai.com/v1/responses | OpenAI endpoint |
| `SLY_OLLAMA_MODEL` | llama3.2 | Ollama model |
| `SLY_OLLAMA_URL` | http://localhost:11434 | Ollama server URL |
| `SLY_PROMPT_EXTEND` | - | Additional system prompt text |

### Configuration Loading

```zig
pub fn loadConfigFromEnv(allocator: Allocator) !Config {
    return Config{
        .provider = autoDetectProvider(allocator),
        .anthropic_key = getEnvOpt(allocator, "ANTHROPIC_API_KEY"),
        .anthropic_model = try getEnvOr(allocator, "SLY_ANTHROPIC_MODEL", "claude-3-5-sonnet-20241022"),
        .gemini_key = getEnvOpt(allocator, "GEMINI_API_KEY"),
        .gemini_model = try getEnvOr(allocator, "SLY_GEMINI_MODEL", "gemini-2.0-flash-exp"),
        .openai_key = getEnvOpt(allocator, "OPENAI_API_KEY"),
        .openai_model = try getEnvOr(allocator, "SLY_OPENAI_MODEL", "gpt-4o"),
        .openai_url = try getEnvOr(allocator, "SLY_OPENAI_URL", "https://api.openai.com/v1/responses"),
        .ollama_model = try getEnvOr(allocator, "SLY_OLLAMA_MODEL", "llama3.2"),
        .ollama_url = try getEnvOr(allocator, "SLY_OLLAMA_URL", "http://localhost:11434"),
    };
}
```

## Error Handling

### Error Types

| Error | Cause | User Message |
|-------|-------|--------------|
| `MissingApiKey` | API key not set | "API Error: Missing API key" |
| `InvalidApiKey` | Key too short | "API Error: Invalid API key" |
| `BadResponse` | Unparseable response | "Error: Unable to parse response" |
| `Network` | Connection failed | "Error: Failed to connect" |
| `Unavailable` | Service down | "Error: Service unavailable" |
| `ValidationFailed` | Invalid CommandPlan | "Error: Failed to generate valid plan" |

### Error Messages

```zig
const msg = switch (err) {
    error.MissingApiKey => "API Error: Missing API key",
    error.BadResponse => "Error: Unable to parse response",
    error.Network, error.Unavailable => "Error: Failed to connect to provider",
    error.ValidationFailed => "Error: Failed to generate valid command",
    else => "Error: Unknown",
};
```
