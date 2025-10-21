const std = @import("std");

fn pathExists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

fn detectProjectType() []const u8 {
    if (pathExists("package.json")) return "node";
    if (pathExists("Cargo.toml")) return "rust";
    if (pathExists("requirements.txt") or pathExists("setup.py") or pathExists("pyproject.toml")) return "python";
    if (pathExists("Gemfile")) return "ruby";
    if (pathExists("go.mod")) return "go";
    if (pathExists("composer.json")) return "php";
    if (pathExists("pom.xml") or pathExists("build.gradle")) return "java";
    if (pathExists("docker-compose.yml") or pathExists("Dockerfile")) return "docker";
    return "unknown";
}

fn getGitContext(allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    const is_repo = blk: {
        const pr = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
            .max_output_bytes = 64 * 1024,
        }) catch break :blk false;
        defer allocator.free(pr.stdout);
        defer allocator.free(pr.stderr);
        break :blk pr.term == .Exited and pr.term.Exited == 0 and std.mem.indexOf(u8, pr.stdout, "true") != null;
    };
    if (!is_repo) return result.toOwnedSlice(allocator);

    var branch: []const u8 = "";
    {
        const pr = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "branch", "--show-current" },
            .max_output_bytes = 64 * 1024,
        }) catch {
            return result.toOwnedSlice(allocator);
        };
        defer allocator.free(pr.stdout);
        defer allocator.free(pr.stderr);
        if (pr.term == .Exited and pr.term.Exited == 0) {
            branch = std.mem.trim(u8, pr.stdout, " \n\r\t");
        }
    }

    var dirty = "clean";
    {
        const pr = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "status", "--porcelain" },
            .max_output_bytes = 64 * 1024,
        }) catch {
            return result.toOwnedSlice(allocator);
        };
        defer allocator.free(pr.stdout);
        defer allocator.free(pr.stderr);
        if (pr.term == .Exited and pr.term.Exited == 0 and pr.stdout.len > 0) dirty = "dirty";
    }

    try result.writer(allocator).print("Git: branch={s}, status={s}", .{ branch, dirty });
    return result.toOwnedSlice(allocator);
}

fn firstNFiles(allocator: std.mem.Allocator, max_list: usize) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    var it = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return list.toOwnedSlice(allocator);
    defer it.close();

    var iter = it.iterate();
    var names: std.ArrayList([]u8) = .{};
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    while (try iter.next()) |entry| {
        if (names.items.len >= 20) break;
        if (entry.kind != .directory and entry.kind != .sym_link) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    const total = names.items.len;
    if (total == 0) return list.toOwnedSlice(allocator);

    const show = @min(max_list, total);
    try list.writer(allocator).writeAll("Files: ");
    for (names.items[0..show], 0..) |name, i| {
        try list.writer(allocator).print("{s}", .{name});
        if (i + 1 < show) try list.writer(allocator).writeAll(", ");
    }
    if (total > show) try list.writer(allocator).print(" ... and {d} more", .{total - show});

    return list.toOwnedSlice(allocator);
}

pub fn buildContext(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    try buf.writer(allocator).print("Current directory: {s}", .{cwd});

    const files_line = try firstNFiles(allocator, 10);
    defer allocator.free(files_line);
    if (files_line.len > 0) {
        try buf.writer(allocator).writeAll("\n");
        try buf.writer(allocator).writeAll(files_line);
    }

    const proj = detectProjectType();
    if (!std.mem.eql(u8, proj, "unknown")) {
        try buf.writer(allocator).print("\nProject type: {s}", .{proj});
    }

    const git = try getGitContext(allocator);
    defer allocator.free(git);
    if (git.len > 0) {
        try buf.writer(allocator).print("\n{s}", .{git});
    }

    const os_name = switch (@import("builtin").os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        else => "Unix",
    };
    try buf.writer(allocator).print("\nOS: {s}", .{os_name});

    return buf.toOwnedSlice(allocator);
}
