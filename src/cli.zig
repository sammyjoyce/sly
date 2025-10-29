const std = @import("std");
const argzon = @import("argzon");

const CLI = @import("cli.zon");

pub const Args = argzon.Args(CLI, .{});

pub const ShellInstallArgs = struct {
    shell: ?[]const u8 = null,
    auto: bool = false,
};

pub const Command = union(enum) {
    version,
    help,
    shell_install: ShellInstallArgs,
    query: []const u8,
};

pub const ParseResult = struct {
    command: Command,
    args: ?Args,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParseResult) void {
        if (self.args) |*args| {
            args.free(self.allocator);
        }
        switch (self.command) {
            .query => |q| self.allocator.free(q),
            .shell_install => |install| {
                if (install.shell) |s| self.allocator.free(s);
            },
            else => {},
        }
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !ParseResult {
    // First, peek at arguments to determine if this is a query or subcommand
    var arg_str_iter = try std.process.argsWithAllocator(allocator);
    defer arg_str_iter.deinit();

    // Skip program name
    _ = arg_str_iter.next();

    // Peek at first argument
    const first_arg = arg_str_iter.next();

    // Check if first argument suggests we should use argzon parsing
    const use_argzon = if (first_arg) |arg|
        std.mem.eql(u8, arg, "shell") or
            std.mem.eql(u8, arg, "--version") or
            std.mem.eql(u8, arg, "-v") or
            std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h")
    else
        false;

    if (use_argzon) {
        // Re-create iterator for argzon parsing
        var arg_str_iter2 = try std.process.argsWithAllocator(allocator);
        defer arg_str_iter2.deinit();

        var stderr_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);

        // Parse command-line arguments
        const args: Args = try .parse(allocator, &arg_str_iter2, &stderr_writer.interface, .{});

        // Check for version flag
        if (args.flags.version) {
            return ParseResult{ .command = .version, .args = args, .allocator = allocator };
        }

        // Check for shell subcommand
        if (args.subcommands_opt) |subcommands| {
            switch (subcommands) {
                .shell => |shell_cmd| {
                    switch (shell_cmd.subcommands_opt.?) {
                        .install => |install_cmd| {
                            var install_args = ShellInstallArgs{
                                .auto = install_cmd.flags.auto,
                            };

                            if (install_cmd.options.shell) |shell_str| {
                                install_args.shell = try allocator.dupe(u8, shell_str);
                            }

                            return ParseResult{
                                .command = .{ .shell_install = install_args },
                                .args = args,
                                .allocator = allocator,
                            };
                        },
                    }
                },
            }
        }

        // Check if help was requested
        return ParseResult{ .command = .help, .args = args, .allocator = allocator };
    }

    // Not a subcommand or flag - treat everything as a query
    if (first_arg) |arg| {
        // Count total length needed
        var total_len: usize = arg.len;
        var arg_count: usize = 1;

        // Peek at remaining args to calculate size
        var temp_iter = try std.process.argsWithAllocator(allocator);
        defer temp_iter.deinit();
        _ = temp_iter.next(); // skip program name
        _ = temp_iter.next(); // skip first arg (already counted)
        while (temp_iter.next()) |next_arg| {
            total_len += 1 + next_arg.len; // space + arg
            arg_count += 1;
        }

        // Allocate and build query string
        const query = try allocator.alloc(u8, total_len);
        var pos: usize = 0;

        @memcpy(query[pos..][0..arg.len], arg);
        pos += arg.len;

        while (arg_str_iter.next()) |next_arg| {
            query[pos] = ' ';
            pos += 1;
            @memcpy(query[pos..][0..next_arg.len], next_arg);
            pos += next_arg.len;
        }

        return ParseResult{
            .command = .{ .query = query },
            .args = null,
            .allocator = allocator,
        };
    }

    // No arguments - show help
    return ParseResult{ .command = .help, .args = null, .allocator = allocator };
}
