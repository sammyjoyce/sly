/// PTY Manager - Pseudo-terminal management for command execution
///
/// This module provides PTY creation and management for executing shell commands
/// while capturing their output through a TerminalRuntime instance.
///
/// Key features:
/// - PTY creation with size configuration
/// - Command execution in subprocess
/// - Streaming output capture to TerminalRuntime
/// - Timeout support for command execution
/// - Proper cleanup on error or completion
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const terminal_runtime = @import("terminal_runtime.zig");

const log = std.log.scoped(.pty_manager);

// Platform-specific imports
const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("util.h"); // openpty()
        @cInclude("termios.h");
        @cInclude("unistd.h"); // setsid()
    }),
    .freebsd => @cImport({
        @cInclude("termios.h");
        @cInclude("libutil.h"); // openpty()
        @cInclude("sys/ioctl.h");
        @cInclude("unistd.h"); // setsid()
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("pty.h");
        @cInclude("termios.h");
        @cInclude("unistd.h"); // setsid()
    }),
};

/// PTY window size structure
pub const Winsize = extern struct {
    ws_row: u16 = 24,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

/// Result of command execution
pub const ExecResult = struct {
    /// Exit code of the command
    exit_code: i32,

    /// Final snapshot of terminal state
    snapshot: terminal_runtime.Snapshot,

    /// Total bytes read from PTY
    bytes_read: usize,

    /// Whether execution was terminated due to timeout
    timed_out: bool,

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
    }
};

/// PTY Session for command execution
pub const PtySession = struct {
    /// Master side of the PTY (parent process uses this)
    master: posix.fd_t,

    /// Slave side of the PTY (child process uses this)
    slave: posix.fd_t,

    /// Child process handle
    process: ?std.process.Child,

    /// Terminal runtime for output processing
    runtime: *terminal_runtime.TerminalRuntime,

    /// Allocator for buffers
    allocator: std.mem.Allocator,

    /// Initialize a PTY session and spawn a command
    pub fn spawn(
        allocator: std.mem.Allocator,
        command: []const u8,
        args: []const []const u8,
        env_map: ?*const std.process.EnvMap,
        runtime: *terminal_runtime.TerminalRuntime,
        size: Winsize,
    ) !PtySession {
        // Open PTY
        var master_fd: posix.fd_t = undefined;
        var slave_fd: posix.fd_t = undefined;

        var size_copy = size;
        if (c.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&size_copy),
        ) < 0) {
            log.err("openpty failed: {s}", .{@tagName(posix.errno(-1))});
            return error.OpenptyFailed;
        }
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }

        // Set CLOEXEC on master fd (only slave should be inherited by child)
        setCloexec(master_fd) catch |err| {
            log.warn("failed to set CLOEXEC on master fd: {}", .{err});
        };

        // Enable UTF-8 mode
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0) {
            return error.TcgetattrFailed;
        }
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0) {
            return error.TcsetattrFailed;
        }

        // Fork first, then build command in child
        const pid = try posix.fork();

        if (pid == 0) {
            // Child process - build argv here
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const child_alloc = arena.allocator();

            var argv_list = std.ArrayList([]const u8){};
            argv_list.append(child_alloc, command) catch posix.exit(1);
            for (args) |arg| {
                argv_list.append(child_alloc, arg) catch posix.exit(1);
            }

            childSetup(slave_fd, argv_list.items, env_map) catch |err| {
                log.err("child setup failed: {}", .{err});
                posix.exit(1);
            };
            // Should not reach here
            unreachable;
        }

        // Parent process - close slave fd (child has it)
        _ = posix.system.close(slave_fd);

        return PtySession{
            .master = master_fd,
            .slave = 0, // closed
            .process = null, // We'll wait via pid
            .runtime = runtime,
            .allocator = allocator,
        };
    }

    /// Write data to the PTY input
    pub fn write(self: *PtySession, data: []const u8) !void {
        const written = try posix.write(self.master, data);
        if (written != data.len) {
            return error.PartialWrite;
        }
    }

    /// Read data from PTY output into buffer
    /// Returns number of bytes read (0 = EOF)
    pub fn read(self: *PtySession, buffer: []u8) !usize {
        return posix.read(self.master, buffer) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    /// Execute command and stream output to runtime
    /// Returns when process exits or timeout is reached
    pub fn executeWithTimeout(
        self: *PtySession,
        timeout_ms: ?u64,
    ) !ExecResult {
        var buffer: [4096]u8 = undefined;
        var total_bytes: usize = 0;
        var timed_out = false;

        const start_time = std.time.milliTimestamp();

        // Set master fd to non-blocking mode
        try setNonBlocking(self.master);

        // Read loop
        while (true) {
            // Check timeout
            if (timeout_ms) |timeout| {
                const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed >= timeout) {
                    timed_out = true;
                    break;
                }
            }

            // Try to read
            const bytes_read = self.read(&buffer) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms); // Sleep 10ms
                    continue;
                }
                return err;
            };

            if (bytes_read == 0) {
                // EOF - process likely exited
                break;
            }

            // Feed to runtime
            try self.runtime.feedBytes(buffer[0..bytes_read]);
            total_bytes += bytes_read;
        }

        // Wait for process (non-blocking check)
        var exit_code: i32 = 0;
        // TODO: Implement proper process wait using pid
        // For now, assume success
        exit_code = 0;

        // Capture final snapshot
        const snapshot = try self.runtime.snapshot(.{});

        return ExecResult{
            .exit_code = exit_code,
            .snapshot = snapshot,
            .bytes_read = total_bytes,
            .timed_out = timed_out,
        };
    }

    /// Close the PTY session
    pub fn close(self: *PtySession) void {
        if (self.master != 0) {
            _ = posix.system.close(self.master);
            self.master = 0;
        }
    }
};

/// Child process setup - called after fork() in child
fn childSetup(
    slave_fd: posix.fd_t,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap,
) !void {
    _ = env_map; // TODO: Apply environment variables

    // Create new session
    _ = c.setsid();

    // Set controlling terminal
    const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
    if (c.ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0)) < 0) {
        posix.exit(1);
    }

    // Redirect stdin/stdout/stderr to slave
    posix.dup2(slave_fd, posix.STDIN_FILENO) catch posix.exit(1);
    posix.dup2(slave_fd, posix.STDOUT_FILENO) catch posix.exit(1);
    posix.dup2(slave_fd, posix.STDERR_FILENO) catch posix.exit(1);

    // Close the original slave fd if it's not one of std fds
    if (slave_fd > posix.STDERR_FILENO) {
        _ = posix.system.close(slave_fd);
    }

    // Build null-terminated argv for execvpe
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const argv_z = alloc.allocSentinel(?[*:0]const u8, argv.len, null) catch posix.exit(1);
    for (argv, 0..) |arg, i| {
        argv_z[i] = alloc.dupeZ(u8, arg) catch posix.exit(1);
    }

    // Use current environment
    const envp: [*:null]const ?[*:0]const u8 = @extern([*:null]const ?[*:0]const u8, .{ .name = "environ" });

    // Execute command using execvpe
    const err = posix.execvpeZ_expandArg0(.no_expand, argv_z[0].?, argv_z[0..argv.len :null], envp);
    log.err("execvpe failed: {}", .{err});
    posix.exit(1);
}

/// Set CLOEXEC flag on file descriptor
fn setCloexec(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}

/// Set file descriptor to non-blocking mode
fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    // O_NONBLOCK on Linux x86_64 is 0o4000 (octal) or 0x800 (hex)
    const O_NONBLOCK: u32 = 0o4000;
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
}

// Tests
test "pty session basic creation" {
    // Skip PTY integration test - requires actual TTY and fork capabilities
    // This test validates end-to-end PTY creation and command execution
    // Run manually with: zig build test-pty (TODO: create separate test target)
    return error.SkipZigTest;
}

test "pty session with styled output" {
    // Skip PTY integration test - requires actual TTY and fork capabilities
    // This test validates ANSI code processing through PTY
    // Run manually with: zig build test-pty (TODO: create separate test target)
    return error.SkipZigTest;
}
