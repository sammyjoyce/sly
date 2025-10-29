const std = @import("std");
const sly = @import("sly.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    // Collect all arguments into a query string
    var query_buf = std.ArrayList(u8){};
    defer query_buf.deinit(alloc);

    // Check for flags first
    const first_arg = args_iter.next();
    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            var stdout_buf: [4096]u8 = undefined;
            const stdout_file = std.fs.File.stdout();
            var stdout_writer = stdout_file.writer(&stdout_buf);
            try stdout_writer.interface.print("sly {s}\n", .{sly.version});
            try stdout_writer.interface.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout_buf: [4096]u8 = undefined;
            const stdout_file = std.fs.File.stdout();
            var stdout_writer = stdout_file.writer(&stdout_buf);
            try stdout_writer.interface.print(
                \\sly {s} - Shell AI command generator
                \\
                \\Usage: sly [OPTIONS] "natural language query"
                \\
                \\Options:
                \\  -h, --help     Show this help message
                \\  -v, --version  Show version information
                \\
                \\Examples:
                \\  sly "list all pdf files"
                \\  sly "show disk usage sorted by size"
                \\
                \\Environment Variables:
                \\  SLY_PROVIDER            AI provider (anthropic, gemini, openai, ollama, echo)
                \\  ANTHROPIC_API_KEY       Anthropic API key
                \\  GEMINI_API_KEY          Google Gemini API key
                \\  OPENAI_API_KEY          OpenAI API key
                \\  SLY_PROMPT_EXTEND       Additional system prompt instructions
                \\
                \\For full documentation, see README.md
                \\
            , .{sly.version});
            try stdout_writer.interface.flush();
            return;
        }

        // Not a flag, add to query
        try query_buf.appendSlice(alloc, arg);
    }

    // Collect remaining arguments
    while (args_iter.next()) |arg| {
        try query_buf.append(alloc, ' ');
        try query_buf.appendSlice(alloc, arg);
    }

    const saw_any = query_buf.items.len > 0;

    // Show usage if no arguments provided
    if (!saw_any) {
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const provider_name = std.process.getEnvVarOwned(alloc, "SLY_PROVIDER") catch "anthropic";
        defer if (!std.mem.eql(u8, provider_name, "anthropic")) alloc.free(provider_name);
        try stdout_writer.interface.print("Usage: sly \"your natural language command\"\nCurrent provider: {s}\nRun 'sly --help' for more information.\n", .{provider_name});
        try stdout_writer.interface.flush();
        return;
    }

    const query_text = try query_buf.toOwnedSlice(alloc);
    defer alloc.free(query_text);

    // Load configuration from environment
    const cfg = try sly.loadConfigFromEnv(alloc);
    defer sly.freeConfig(alloc, cfg);

    // Generate the command
    const out_cmd = try sly.generate(alloc, query_text, cfg);
    defer alloc.free(out_cmd);

    // Output the result
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    try stdout_writer.interface.print("{s}", .{out_cmd});
    try stdout_writer.interface.flush();
}
