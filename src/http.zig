//! HTTP Client Module
//!
//! Lightweight HTTP client built on libcurl for making JSON API requests.
//! Designed for AI provider communication in sly.
//!
//! ## Features
//! - JSON POST requests with automatic Content-Type header
//! - Configurable timeouts (connection + total request)
//! - Custom header support for authorization/API keys
//! - Streaming response body collection
//!
//! ## Memory Management
//! Response bodies are allocated with the caller's allocator. The caller
//! owns the returned `Response.body` slice and must free it when done.
//!
//! ## Error Handling
//! - `error.Unavailable`: libcurl initialization failed
//! - `error.Network`: Request failed (timeout, DNS, connection, etc.)
//!
//! ## Example
//! ```zig
//! const response = try http.postJson(
//!     allocator,
//!     "https://api.example.com/v1/chat",
//!     &.{"Authorization: Bearer sk-xxx"},
//!     "{\"prompt\": \"hello\"}",
//! );
//! defer allocator.free(response.body);
//! ```

const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
});

/// HTTP response from a completed request.
///
/// Contains the status code and response body. The caller owns the body
/// memory and must free it with the same allocator used for the request.
pub const Response = struct {
    /// HTTP status code (e.g., 200, 404, 500).
    /// Check this before processing the body - non-2xx codes indicate errors.
    status: u32,

    /// Response body bytes (typically JSON for API responses).
    /// Caller owns this memory and must free with the same allocator.
    /// Empty slice if the server returned no body.
    body: []u8,
};

/// Errors that can occur during HTTP operations.
pub const HttpError = error{
    /// libcurl initialization failed. Typically indicates curl is not
    /// available or system resources are exhausted.
    Unavailable,

    /// Network operation failed. Could be DNS resolution, connection
    /// refused, timeout, TLS handshake failure, etc.
    Network,

    /// Memory allocation failed.
    OutOfMemory,
};

/// Internal context for libcurl write callback.
const WriteCtx = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

/// libcurl write callback - collects response body bytes.
fn writeCb(ptr: ?*const anyopaque, size: usize, nmemb: usize, userp: ?*anyopaque) callconv(.c) usize {
    if (ptr == null or userp == null) return 0;
    const total: usize = size * nmemb;
    const bytes = @as([*]const u8, @ptrCast(ptr.?))[0..total];

    var ctx = @as(*WriteCtx, @ptrCast(@alignCast(userp.?)));
    ctx.buf.appendSlice(ctx.allocator, bytes) catch return 0;

    return total;
}

/// Append a header string to a curl slist.
fn slistAppend(head: ?*c.struct_curl_slist, s: []const u8) ?*c.struct_curl_slist {
    const z = std.heap.c_allocator.dupeZ(u8, s) catch return head;
    return c.curl_slist_append(head, @ptrCast(z));
}

/// Calculate connection timeout from total timeout.
///
/// Connection timeout is set to half of the total timeout, capped at 10 seconds.
/// This ensures connection attempts don't consume the entire timeout budget.
pub fn calculateConnectTimeout(timeout_ms: u32) u32 {
    return @min(timeout_ms / 2, 10000);
}

/// Sends a POST request with JSON content type and a 30-second timeout.
///
/// Convenience wrapper around `postJsonWithTimeout` with a 30-second default.
/// Suitable for most AI API calls.
///
/// ## Parameters
/// - `allocator`: Allocator for response body and temporary buffers.
/// - `url`: Full URL including scheme (e.g., "https://api.openai.com/v1/chat").
/// - `headers`: Additional headers (e.g., `&.{"Authorization: Bearer sk-xxx"}`).
///   Content-Type is added automatically.
/// - `body`: Request body bytes (typically JSON-encoded).
///
/// ## Returns
/// `Response` with status code and body. Caller owns `response.body`.
///
/// ## Errors
/// - `error.Unavailable`: libcurl failed to initialize
/// - `error.Network`: Request failed (timeout, DNS, TLS, etc.)
/// - `error.OutOfMemory`: Allocation failed
pub fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !Response {
    return postJsonWithTimeout(allocator, url, headers, body, 30000);
}

/// Sends a POST request with JSON content type and configurable timeout.
///
/// Low-level function for JSON POST requests with full timeout control.
/// The `Content-Type: application/json` header is added automatically.
///
/// ## Parameters
/// - `allocator`: Allocator for response body and temporary buffers.
/// - `url`: Full URL including scheme.
/// - `headers`: Additional headers. Content-Type is added automatically.
/// - `body`: Request body bytes (typically JSON-encoded).
/// - `timeout_ms`: Total request timeout in milliseconds. Connection timeout
///   is set to half this value, capped at 10 seconds.
///
/// ## Returns
/// `Response` with status code and body. Caller owns `response.body`.
///
/// ## Errors
/// - `error.Unavailable`: libcurl failed to initialize
/// - `error.Network`: Request failed (timeout, DNS, TLS, etc.)
/// - `error.OutOfMemory`: Allocation failed
///
/// ## Memory Management
/// The returned `Response.body` is allocated with `allocator`. The caller
/// must free it when done: `allocator.free(response.body)`.
pub fn postJsonWithTimeout(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
) !Response {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    const eh = c.curl_easy_init();
    if (eh == null) return error.Unavailable;
    defer c.curl_easy_cleanup(eh);

    // Set URL
    const urlz = try allocator.dupeZ(u8, url);
    defer allocator.free(urlz);
    _ = c.curl_easy_setopt(eh, c.CURLOPT_URL, urlz.ptr);

    // Set method + body
    _ = c.curl_easy_setopt(eh, c.CURLOPT_POST, @as(c_long, 1));
    _ = c.curl_easy_setopt(eh, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
    _ = c.curl_easy_setopt(eh, c.CURLOPT_POSTFIELDS, body.ptr);

    // Set headers
    var list: ?*c.struct_curl_slist = null;
    list = slistAppend(list, "Content-Type: application/json");
    for (headers) |h| list = slistAppend(list, h);
    defer if (list) |l| c.curl_slist_free_all(l);
    _ = c.curl_easy_setopt(eh, c.CURLOPT_HTTPHEADER, list);

    // Set timeouts
    const connect_timeout = @min(timeout_ms / 2, 10000);
    _ = c.curl_easy_setopt(eh, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(connect_timeout)));
    _ = c.curl_easy_setopt(eh, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(timeout_ms)));

    // Set write callback
    var ctx = WriteCtx{ .buf = &out, .allocator = allocator };
    _ = c.curl_easy_setopt(eh, c.CURLOPT_WRITEFUNCTION, @as(?*const anyopaque, @ptrCast(&writeCb)));
    _ = c.curl_easy_setopt(eh, c.CURLOPT_WRITEDATA, @as(?*anyopaque, @ptrCast(&ctx)));

    // Perform request
    const rc = c.curl_easy_perform(eh);
    if (rc != c.CURLE_OK) return error.Network;

    // Get response code
    var code_long: c_long = 0;
    _ = c.curl_easy_getinfo(eh, c.CURLINFO_RESPONSE_CODE, &code_long);

    return Response{
        .status = @intCast(code_long),
        .body = try out.toOwnedSlice(allocator),
    };
}
