/// PTY Manager - Pseudo-terminal management for command execution
///
/// This module provides PTY (pseudo-terminal) creation and management for executing
/// shell commands while capturing their output through a TerminalRuntime instance.
/// It handles the low-level details of PTY allocation, process forking, and I/O
/// multiplexing so that callers can focus on command execution semantics.
///
/// ## Key Features
/// - Cross-platform PTY creation (Linux, macOS, FreeBSD)
/// - PTY window size configuration (rows, columns, pixels)
/// - Subprocess spawning with proper session/controlling terminal setup
/// - Streaming output capture fed directly to TerminalRuntime for VT parsing
/// - Timeout support for bounded command execution
/// - Proper resource cleanup on error or completion
///
/// ## Usage Flow
/// 1. Create a `TerminalRuntime` to receive and parse PTY output
/// 2. Call `PtySession.spawn()` with command, args, environment, and the runtime
/// 3. Call `executeWithTimeout()` to run the command and capture output
/// 4. Access the `ExecResult` for exit code, terminal snapshot, and timing info
/// 5. Call `close()` to release PTY resources
///
/// ## Platform Notes
/// Uses `openpty()` which is available on POSIX systems. The implementation
/// handles platform-specific header differences (util.h on macOS, pty.h on Linux).
/// Windows is not supported (no PTY equivalent in this implementation).
///
/// ## Thread Safety
/// Not thread-safe. A `PtySession` should be used from a single thread.
/// The underlying TerminalRuntime is also not thread-safe.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const terminal_runtime = @import("terminal_runtime.zig");

const log = std.log.scoped(.pty_manager);

// Platform-specific imports for PTY operations.
// Each platform has slightly different headers for openpty(), termios, and ioctl.
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

/// PTY window size structure matching the kernel's `struct winsize`.
///
/// Used to configure the initial size of the PTY and can be updated
/// via `TIOCSWINSZ` ioctl if the terminal is resized. The pixel dimensions
/// are optional and typically set to approximate values.
///
/// Default values create an 80x24 character terminal (standard VT100 size).
pub const Winsize = extern struct {
    /// Number of rows (lines) in the terminal. Default: 24.
    ws_row: u16 = 24,

    /// Number of columns (characters per line) in the terminal. Default: 80.
    ws_col: u16 = 80,

    /// Horizontal size in pixels (informational, often approximate). Default: 800.
    ws_xpixel: u16 = 800,

    /// Vertical size in pixels (informational, often approximate). Default: 600.
    ws_ypixel: u16 = 600,
};

/// Result of command execution containing exit status and captured output.
///
/// Returned by `PtySession.executeWithTimeout()` after a command completes
/// (either normally, via timeout, or by error). Contains everything needed
/// to understand what happened during execution.
///
/// ## Memory Ownership
/// The `snapshot` field contains allocated memory that must be freed by
/// calling `deinit()` when the result is no longer needed.
pub const ExecResult = struct {
    /// Exit code from the child process.
    ///
    /// Values:
    /// - 0: Success (by convention)
    /// - 1-255: Command-specific error codes
    /// - -1: Process did not exit normally (killed by signal)
    exit_code: i32,

    /// Final snapshot of the terminal state after command execution.
    ///
    /// Contains the framebuffer content, cursor position, styling,
    /// and any OSC events captured during execution. This represents
    /// what a user would see on screen after the command completes.
    snapshot: terminal_runtime.Snapshot,

    /// Total number of bytes read from the PTY during execution.
    ///
    /// Useful for debugging and understanding command output volume.
    /// Does not include any bytes that may have been lost due to
    /// buffer limits in the terminal runtime.
    bytes_read: usize,

    /// Whether execution was terminated due to timeout expiration.
    ///
    /// When true, the command may still be running (or have been killed)
    /// and the snapshot represents a partial execution state. The exit_code
    /// may not be meaningful in this case.
    timed_out: bool,

    /// Free all owned memory associated with this result.
    ///
    /// Must be called when the ExecResult is no longer needed to avoid
    /// memory leaks. Safe to call multiple times.
    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
    }
};

/// PTY Session for command execution with terminal emulation.
///
/// Encapsulates a pseudo-terminal pair (master/slave), a forked child process,
/// and a TerminalRuntime for parsing VT escape sequences. The session manages
/// the full lifecycle from spawn to cleanup.
///
/// ## Architecture
/// ```
///  Parent Process                 Child Process
///  ┌─────────────┐               ┌─────────────┐
///  │ PtySession  │               │   Command   │
///  │  (master)   │◄──────PTY────►│   (slave)   │
///  │      │      │               └─────────────┘
///  │      ▼      │
///  │ Terminal    │
///  │  Runtime    │
///  └─────────────┘
/// ```
///
/// The master side reads command output and feeds it to TerminalRuntime.
/// The slave side becomes stdin/stdout/stderr for the child process.
///
/// ## Lifecycle
/// 1. `spawn()` - Create PTY, fork, exec command in child
/// 2. `write()` - Optional: send input to the command
/// 3. `read()` or `executeWithTimeout()` - Capture output
/// 4. `close()` - Release resources
pub const PtySession = struct {
    /// Master side file descriptor of the PTY pair.
    ///
    /// The parent process uses this to read child output and write input.
    /// Set to 0 after close() is called.
    master: posix.fd_t,

    /// Slave side file descriptor of the PTY pair.
    ///
    /// Passed to the child process and closed in the parent after fork.
    /// Always 0 in the parent after spawn() returns successfully.
    slave: posix.fd_t,

    /// Process ID of the forked child process running the command.
    ///
    /// Used to wait for process completion and retrieve exit status.
    child_pid: posix.pid_t,

    /// Reference to the TerminalRuntime that processes PTY output.
    ///
    /// Output bytes read from the master fd are fed to this runtime
    /// for VT sequence parsing and framebuffer updates. The runtime
    /// must outlive the PtySession.
    runtime: *terminal_runtime.TerminalRuntime,

    /// Allocator used for internal buffers during command execution.
    allocator: std.mem.Allocator,

    /// Create a PTY session and spawn a command as a child process.
    ///
    /// Opens a pseudo-terminal pair, configures it for UTF-8 mode, forks,
    /// and executes the specified command in the child process. The child's
    /// stdin/stdout/stderr are connected to the slave side of the PTY.
    ///
    /// ## Parameters
    /// - `allocator`: Used for building argv in the child process.
    /// - `command`: Path or name of the executable to run.
    /// - `args`: Command-line arguments (not including the command itself).
    /// - `env_map`: Environment variables for the child, or null to inherit.
    /// - `runtime`: TerminalRuntime that will receive PTY output.
    /// - `size`: Initial PTY window size (rows, columns).
    ///
    /// ## Returns
    /// An initialized PtySession with the child process running.
    ///
    /// ## Errors
    /// - `error.OpenptyFailed`: Could not allocate PTY pair.
    /// - `error.TcgetattrFailed`: Could not get terminal attributes.
    /// - `error.TcsetattrFailed`: Could not set UTF-8 mode.
    /// - `error.ForkFailed`: fork() system call failed.
    /// - `error.OutOfMemory`: Allocation failure.
    ///
    /// ## Notes
    /// The command is resolved using PATH (via execvpe). If the command
    /// cannot be found or executed, the child process exits with code 1.
    pub fn spawn(
        allocator: std.mem.Allocator,
        command: []const u8,
        args: []const []const u8,
        env_map: ?*const std.process.EnvMap,
        runtime: *terminal_runtime.TerminalRuntime,
        size: Winsize,
    ) !PtySession {
        // Open PTY pair using platform's openpty() function.
        // This creates matched master/slave file descriptors.
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

        // Set CLOEXEC on master fd so only the slave is inherited by the child.
        // This prevents the child from accidentally writing to the master.
        setCloexec(master_fd) catch |err| {
            log.warn("failed to set CLOEXEC on master fd: {}", .{err});
        };

        // Enable UTF-8 mode on the PTY for proper Unicode handling.
        // IUTF8 tells the terminal driver to use UTF-8 character boundaries
        // for line editing operations like backspace.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0) {
            return error.TcgetattrFailed;
        }
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0) {
            return error.TcsetattrFailed;
        }

        // Fork the process. The child will set up the PTY slave and exec.
        // Building argv in the child avoids allocation issues in parent.
        const pid = try posix.fork();

        if (pid == 0) {
            // Child process: set up environment and exec the command.
            // Uses an arena allocator since we'll exec (and memory is released).
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
            // childSetup calls execvpe which never returns on success.
            unreachable;
        }

        // Parent process: close slave fd (child now owns it via dup2).
        _ = posix.system.close(slave_fd);

        return PtySession{
            .master = master_fd,
            .slave = 0, // closed in parent
            .child_pid = pid,
            .runtime = runtime,
            .allocator = allocator,
        };
    }

    /// Write data to the PTY input (send to the running command).
    ///
    /// Writes bytes to the master fd which appear as input on the slave side.
    /// This is how you would send keystrokes or data to an interactive command.
    ///
    /// ## Parameters
    /// - `data`: Bytes to write to the PTY.
    ///
    /// ## Errors
    /// - `error.PartialWrite`: Not all bytes could be written.
    /// - Other POSIX write errors (EPIPE if child has closed, etc.)
    pub fn write(self: *PtySession, data: []const u8) !void {
        const written = try posix.write(self.master, data);
        if (written != data.len) {
            return error.PartialWrite;
        }
    }

    /// Read data from PTY output into the provided buffer.
    ///
    /// Reads bytes from the master fd (output from the child process).
    /// When the child closes stdout/stderr or exits, this returns 0 (EOF).
    ///
    /// ## Parameters
    /// - `buffer`: Destination buffer for read data.
    ///
    /// ## Returns
    /// Number of bytes read into the buffer. Returns 0 on EOF (child exited
    /// or closed the slave fd). Returns 0 for WouldBlock in non-blocking mode.
    ///
    /// ## Errors
    /// - Standard POSIX read errors (not including WouldBlock, which returns 0).
    pub fn read(self: *PtySession, buffer: []u8) !usize {
        return posix.read(self.master, buffer) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    /// Execute the command and stream output to the TerminalRuntime.
    ///
    /// Runs a read loop that captures all output from the child process,
    /// feeds it to the TerminalRuntime for VT parsing, and waits for the
    /// child to exit. Optionally enforces a timeout.
    ///
    /// ## Parameters
    /// - `timeout_ms`: Maximum execution time in milliseconds, or null for no timeout.
    ///
    /// ## Returns
    /// An `ExecResult` containing the exit code, final terminal snapshot,
    /// bytes read count, and timeout status.
    ///
    /// ## Timeout Behavior
    /// When the timeout expires:
    /// - The read loop stops immediately
    /// - `timed_out` is set to true in the result
    /// - The child process is NOT killed (caller should handle this if needed)
    /// - `waitpid` is still called which may block briefly
    ///
    /// ## Notes
    /// The master fd is set to non-blocking mode for polling with timeout.
    /// The function uses a 10ms sleep between read attempts when no data
    /// is available to avoid busy-waiting.
    pub fn executeWithTimeout(
        self: *PtySession,
        timeout_ms: ?u64,
    ) !ExecResult {
        var buffer: [4096]u8 = undefined;
        var total_bytes: usize = 0;
        var timed_out = false;

        const start_time = std.time.milliTimestamp();

        // Set master fd to non-blocking for polling behavior.
        try setNonBlocking(self.master);

        // Main read loop: capture output until EOF or timeout.
        while (true) {
            // Check if we've exceeded the timeout.
            if (timeout_ms) |timeout| {
                const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed >= timeout) {
                    timed_out = true;
                    break;
                }
            }

            // Attempt to read from the PTY.
            const bytes_read = self.read(&buffer) catch |err| {
                if (err == error.WouldBlock) {
                    // No data available; sleep briefly to avoid busy-wait.
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            if (bytes_read == 0) {
                // EOF: child closed the PTY slave (likely exited).
                break;
            }

            // Feed captured bytes to the TerminalRuntime for VT parsing.
            try self.runtime.feedBytes(buffer[0..bytes_read]);
            total_bytes += bytes_read;
        }

        // Wait for the child process to exit and retrieve its status.
        // This cleans up the zombie process and gets the exit code.
        const wait_result = posix.waitpid(self.child_pid, 0);
        const exit_code: i32 = if (wait_result.status.Exited) |code| @intCast(code) else -1;

        // Capture the final terminal state as a snapshot.
        const snapshot = try self.runtime.snapshot(.{});

        return ExecResult{
            .exit_code = exit_code,
            .snapshot = snapshot,
            .bytes_read = total_bytes,
            .timed_out = timed_out,
        };
    }

    /// Close the PTY session and release resources.
    ///
    /// Closes the master file descriptor. Safe to call multiple times.
    /// Does NOT kill or wait for the child process; that should be done
    /// via `executeWithTimeout()` or manually before calling close().
    ///
    /// ## Notes
    /// After calling close(), the PtySession should not be used for
    /// read/write operations. The child process may receive SIGHUP
    /// when the master fd is closed.
    pub fn close(self: *PtySession) void {
        if (self.master != 0) {
            _ = posix.system.close(self.master);
            self.master = 0;
        }
    }
};

/// Set up the child process environment after fork().
///
/// This function is called in the child process (after fork, before exec)
/// to configure the PTY slave as the controlling terminal and redirect
/// standard file descriptors.
///
/// ## Setup Steps
/// 1. Create a new session (setsid) to detach from parent's controlling terminal
/// 2. Set the slave fd as the controlling terminal (TIOCSCTTY)
/// 3. Duplicate slave fd to stdin/stdout/stderr
/// 4. Close the original slave fd
/// 5. Execute the command with execvpe
///
/// ## Parameters
/// - `slave_fd`: The slave side of the PTY to use for I/O.
/// - `argv`: Null-terminated argument array (argv[0] is the command).
/// - `env_map`: Environment variables, or null to inherit from parent.
///
/// ## Notes
/// This function does not return on success (exec replaces the process).
/// On any error, it calls posix.exit(1) to terminate the child.
fn childSetup(
    slave_fd: posix.fd_t,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap,
) !void {
    // Create a new session, making this process the session leader.
    // This detaches from the parent's controlling terminal.
    _ = c.setsid();

    // Set the slave fd as the controlling terminal for this session.
    // TIOCSCTTY: "TIo Control Set Controlling TTY"
    const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
    if (c.ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0)) < 0) {
        posix.exit(1);
    }

    // Redirect standard file descriptors to the PTY slave.
    // After this, the child's stdin/stdout/stderr all go through the PTY.
    posix.dup2(slave_fd, posix.STDIN_FILENO) catch posix.exit(1);
    posix.dup2(slave_fd, posix.STDOUT_FILENO) catch posix.exit(1);
    posix.dup2(slave_fd, posix.STDERR_FILENO) catch posix.exit(1);

    // Close the original slave fd if it's not one of the standard fds.
    // (It's now duplicated to 0, 1, 2 so we don't need the original.)
    if (slave_fd > posix.STDERR_FILENO) {
        _ = posix.system.close(slave_fd);
    }

    // Build null-terminated argv array for execvpe.
    // Using page_allocator since we're about to exec anyway.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const argv_z = alloc.allocSentinel(?[*:0]const u8, argv.len, null) catch posix.exit(1);
    for (argv, 0..) |arg, i| {
        argv_z[i] = alloc.dupeZ(u8, arg) catch posix.exit(1);
    }

    // Build environment: use provided env_map or inherit current environment.
    const envp: [*:null]const ?[*:0]const u8 = if (env_map) |em| blk: {
        const env_count = em.count();
        const envp_buf = alloc.allocSentinel(?[*:0]const u8, env_count, null) catch posix.exit(1);
        var i: usize = 0;
        var iter = em.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            const env_str = std.fmt.allocPrintZ(alloc, "{s}={s}", .{ key, value }) catch posix.exit(1);
            envp_buf[i] = env_str.ptr;
            i += 1;
        }
        break :blk envp_buf.ptr;
    } else @extern([*:null]const ?[*:0]const u8, .{ .name = "environ" });

    // Execute the command. This replaces the current process image.
    // On success, this call never returns.
    const err = posix.execvpeZ_expandArg0(.no_expand, argv_z[0].?, argv_z[0..argv.len :null], envp);
    log.err("execvpe failed: {}", .{err});
    posix.exit(1);
}

/// Set the FD_CLOEXEC flag on a file descriptor.
///
/// Marks the file descriptor to be automatically closed when exec() is called.
/// This prevents file descriptors from leaking into child processes.
///
/// ## Parameters
/// - `fd`: File descriptor to modify.
///
/// ## Errors
/// - POSIX fcntl errors (EBADF if fd is invalid, etc.)
fn setCloexec(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}

/// Set a file descriptor to non-blocking mode.
///
/// When a file descriptor is non-blocking, read() and write() return
/// immediately with EAGAIN/EWOULDBLOCK instead of blocking when no
/// data is available or the buffer is full.
///
/// ## Parameters
/// - `fd`: File descriptor to modify.
///
/// ## Errors
/// - POSIX fcntl errors (EBADF if fd is invalid, etc.)
fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    // O_NONBLOCK is 0o4000 (octal) on Linux x86_64
    const O_NONBLOCK: u32 = 0o4000;
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
}

// =============================================================================
// Tests
// =============================================================================

test "pty session basic creation" {
    // Skip PTY integration test - requires actual TTY and fork capabilities.
    // This test validates end-to-end PTY creation and command execution.
    // Run manually with: zig build test-pty (TODO: create separate test target)
    return error.SkipZigTest;
}

test "pty session with styled output" {
    // Skip PTY integration test - requires actual TTY and fork capabilities.
    // This test validates ANSI code processing through PTY.
    // Run manually with: zig build test-pty (TODO: create separate test target)
    return error.SkipZigTest;
}
