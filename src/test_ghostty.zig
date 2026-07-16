/// Simple test to verify libghostty integration
const std = @import("std");
const ghostty = @import("libghostty.zig");
const TerminalRuntime = @import("terminal_runtime.zig").TerminalRuntime;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Testing libghostty integration...\n", .{});
    
    // Test 1: Create key encoder
    std.debug.print("\n1. Creating key encoder...\n", .{});
    var encoder: ghostty.KeyEncoder = undefined;
    const result = ghostty.key_encoder_new(null, &encoder);
    
    if (ghostty.isSuccess(result)) {
        std.debug.print("   ✓ Key encoder created successfully\n", .{});
        defer ghostty.key_encoder_free(encoder);
        
        // Enable Kitty keyboard protocol
        var flags: ghostty.KittyKeyFlags = ghostty.KITTY_KEY_ALL;
        ghostty.key_encoder_setopt(encoder, ghostty.KEY_ENCODER_OPT_KITTY_FLAGS, &flags);
        std.debug.print("   ✓ Kitty keyboard protocol enabled\n", .{});
    } else {
        std.debug.print("   ✗ Failed to create key encoder: {s}\n", .{ghostty.resultMessage(result)});
        return error.TestFailed;
    }
    
    // Test 2: Create and encode a key event
    std.debug.print("\n2. Creating and encoding key event...\n", .{});
    var event: ghostty.KeyEvent = undefined;
    const event_result = ghostty.key_event_new(null, &event);
    
    if (ghostty.isSuccess(event_result)) {
        defer ghostty.key_event_free(event);
        
        // First test: Check required buffer size
        var required: usize = 0;
        _ = ghostty.key_encoder_encode(encoder, event, null, 0, &required);
        std.debug.print("   Buffer size check works: required={} bytes\n", .{required});
        
        // Set up Enter key event
        ghostty.key_event_set_action(event, ghostty.KEY_ACTION_PRESS);
        ghostty.key_event_set_key(event, ghostty.c.GHOSTTY_KEY_ENTER);
        ghostty.key_event_set_mods(event, 0);
        
        var buffer: [128]u8 = undefined;
        var written: usize = 0;
        
        var encode_result = ghostty.key_encoder_encode(encoder, event, &buffer, buffer.len, &written);
        
        if (ghostty.isSuccess(encode_result)) {
            std.debug.print("   ✓ Encoded Enter: ", .{});
            for (buffer[0..written]) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print(" ({} bytes)\n", .{written});
        } else {
            std.debug.print("   ✗ Failed to encode Enter: {s}\n", .{ghostty.resultMessage(encode_result)});
            return error.TestFailed;
        }
        
        // Test Ctrl+C (Note: Ctrl+C traditionally just sends 0x03, not an escape sequence)
        // In Kitty keyboard protocol with all features, it might have an encoding
        ghostty.key_event_set_key(event, ghostty.c.GHOSTTY_KEY_C);
        ghostty.key_event_set_mods(event, ghostty.MODS_CTRL);
        written = 0;
        
        encode_result = ghostty.key_encoder_encode(encoder, event, &buffer, buffer.len, &written);
        
        if (ghostty.isSuccess(encode_result)) {
            if (written > 0) {
                std.debug.print("   ✓ Encoded Ctrl+C: ", .{});
                for (buffer[0..written]) |byte| {
                    std.debug.print("{x:0>2}", .{byte});
                }
                std.debug.print(" ({} bytes)\n", .{written});
            } else {
                std.debug.print("   ✓ Ctrl+C has no encoding (traditional ASCII 0x03)\n", .{});
            }
        } else {
            std.debug.print("   ✗ Failed to encode Ctrl+C: {s}\n", .{ghostty.resultMessage(encode_result)});
            return error.TestFailed;
        }
    } else {
        std.debug.print("   ✗ Failed to create key event: {s}\n", .{ghostty.resultMessage(event_result)});
        return error.TestFailed;
    }
    
    // Test 3: Create terminal runtime
    std.debug.print("\n3. Creating terminal runtime...\n", .{});
    var runtime = try TerminalRuntime.init(allocator, .{
        .cols = 80,
        .rows = 24,
        .enable_kitty_keyboard = true,
    });
    defer runtime.shutdown();
    
    std.debug.print("   ✓ Terminal runtime created: {}x{}\n", .{ runtime.cols, runtime.rows });
    
    // Test 4: Resize terminal
    std.debug.print("\n4. Resizing terminal...\n", .{});
    try runtime.resize(120, 40);
    std.debug.print("   ✓ Terminal resized to {}x{}\n", .{ runtime.cols, runtime.rows });
    
    std.debug.print("\n✓ All tests passed!\n", .{});
}
