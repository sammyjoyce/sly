const std = @import("std");
const ctx = @import("context.zig");
const providers = @import("providers.zig");

fn getenvOwnedOr(alloc: std.mem.Allocator, k: []const u8, def: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(alloc, k) catch try alloc.dupe(u8, def);
}

fn getenvOwnedOpt(alloc: std.mem.Allocator, k: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(alloc, k) catch null;
}

fn systemPrompt(alloc: std.mem.Allocator, context: []const u8, extend: ?[]const u8) ![]u8 {
    const base =
        \\You are a shell command generator. Generate syntactically correct shell commands based on the user's natural language request.
        \\
        \\IMPORTANT RULES:
        \\1. Output ONLY the raw command - no explanations, no markdown, no backticks
        \\2. For arguments containing spaces or special characters, use single quotes
        \\3. Use double quotes only when variable expansion is needed
        \\4. Properly escape special characters within quotes
        \\
        \\Examples:
        \\- echo 'Hello World!'
        \\- echo "Current user: $USER"
        \\- grep 'pattern with spaces' file.txt
        \\- find . -name '*.txt'
    ;

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, base);
    if (extend) |e| {
        try buf.appendSlice(alloc, "\n\n");
        try buf.appendSlice(alloc, e);
    }
    try buf.appendSlice(alloc, "\n\nContext:\n");
    try buf.appendSlice(alloc, context);
    return buf.toOwnedSlice(alloc);
}

fn parseProvider(p: []const u8) providers.Provider {
    if (std.mem.eql(u8, p, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, p, "gemini")) return .gemini;
    if (std.mem.eql(u8, p, "openai")) return .openai;
    if (std.mem.eql(u8, p, "ollama")) return .ollama;
    if (std.mem.eql(u8, p, "echo")) return .echo;
    return .anthropic;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    var query_buf: std.ArrayList(u8) = .{};
    defer query_buf.deinit(alloc);

    var saw_any = false;
    while (args_iter.next()) |arg| {
        if (saw_any) try query_buf.append(alloc, ' ');
        try query_buf.appendSlice(alloc, arg);
        saw_any = true;
    }

    if (!saw_any) {
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const provider_name = std.process.getEnvVarOwned(alloc, "SLY_PROVIDER") catch "anthropic";
        defer if (!std.mem.eql(u8, provider_name, "anthropic")) alloc.free(provider_name);
        try stdout_writer.interface.print("Usage: sly \"your natural language command\"\nCurrent provider: {s}\n", .{provider_name});
        try stdout_writer.interface.flush();
        return;
    }

    const provider_env = try getenvOwnedOr(alloc, "SLY_PROVIDER", "anthropic");
    defer alloc.free(provider_env);

    const cfg = providers.Config{
        .provider = parseProvider(provider_env),
        .anthropic_key = getenvOwnedOpt(alloc, "ANTHROPIC_API_KEY"),
        .anthropic_model = try getenvOwnedOr(alloc, "SLY_ANTHROPIC_MODEL", "claude-3-5-sonnet-20241022"),
        .gemini_key = getenvOwnedOpt(alloc, "GEMINI_API_KEY"),
        .gemini_model = try getenvOwnedOr(alloc, "SLY_GEMINI_MODEL", "gemini-2.0-flash-exp"),
        .openai_key = getenvOwnedOpt(alloc, "OPENAI_API_KEY"),
        .openai_model = try getenvOwnedOr(alloc, "SLY_OPENAI_MODEL", "gpt-4o"),
        .openai_url = try getenvOwnedOr(alloc, "SLY_OPENAI_URL", "https://api.openai.com/v1/responses"),
        .ollama_model = try getenvOwnedOr(alloc, "SLY_OLLAMA_MODEL", "llama3.2"),
        .ollama_url = try getenvOwnedOr(alloc, "SLY_OLLAMA_URL", "http://localhost:11434"),
    };
    defer if (cfg.anthropic_key) |v| alloc.free(v);
    defer if (cfg.gemini_key) |v| alloc.free(v);
    defer if (cfg.openai_key) |v| alloc.free(v);
    defer alloc.free(cfg.anthropic_model);
    defer alloc.free(cfg.gemini_model);
    defer alloc.free(cfg.openai_model);
    defer alloc.free(cfg.openai_url);
    defer alloc.free(cfg.ollama_model);
    defer alloc.free(cfg.ollama_url);

    const extend = getenvOwnedOpt(alloc, "SLY_PROMPT_EXTEND");
    defer if (extend) |e| alloc.free(e);

    const context = try ctx.buildContext(alloc);
    defer alloc.free(context);

    const prompt = try systemPrompt(alloc, context, extend);
    defer alloc.free(prompt);

    const query_text = try query_buf.toOwnedSlice(alloc);
    defer alloc.free(query_text);

    const out_cmd = providers.query(alloc, cfg, query_text, prompt) catch |e| blk: {
        const msg = switch (e) {
            error.MissingApiKey => "API Error: Missing API key",
            error.BadResponse => "Error: Unable to parse response",
            error.Network, error.Unavailable => "Error: Failed to connect to provider",
            else => "Error: Unknown",
        };
        break :blk try alloc.dupe(u8, msg);
    };
    defer alloc.free(out_cmd);

    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    try stdout_writer.interface.print("{s}", .{out_cmd});
    try stdout_writer.interface.flush();
}
