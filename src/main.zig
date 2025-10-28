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

    var saw_any = false;
    while (args_iter.next()) |arg| {
        if (saw_any) try query_buf.append(alloc, ' ');
        try query_buf.appendSlice(alloc, arg);
        saw_any = true;
    }

    // Show usage if no arguments provided
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
