const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Response = struct {
    status: u32,
    body: []u8,
};

const WriteCtx = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

fn writeCb(ptr: ?*const anyopaque, size: usize, nmemb: usize, userp: ?*anyopaque) callconv(.c) usize {
    if (ptr == null or userp == null) return 0;
    const total: usize = size * nmemb;
    const bytes = @as([*]const u8, @ptrCast(ptr.?))[0..total];

    var ctx = @as(*WriteCtx, @ptrCast(@alignCast(userp.?)));
    ctx.buf.appendSlice(ctx.allocator, bytes) catch return 0;

    return total;
}

fn slistAppend(head: ?*c.struct_curl_slist, s: []const u8) ?*c.struct_curl_slist {
    const z = std.heap.c_allocator.dupeZ(u8, s) catch return head;
    return c.curl_slist_append(head, @ptrCast(z));
}

pub fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
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
    _ = c.curl_easy_setopt(eh, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 5000));
    _ = c.curl_easy_setopt(eh, c.CURLOPT_TIMEOUT_MS, @as(c_long, 15000));

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
