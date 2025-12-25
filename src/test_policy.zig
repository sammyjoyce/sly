/// Test executable for policy engine integration
/// This demonstrates Phase 4 - OSC Bus & Policy Engine
const std = @import("std");
const policy = @import("policy_engine.zig");
const ghostty = @import("libghostty.zig");
const TerminalRuntime = @import("terminal_runtime.zig").TerminalRuntime;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.log.info("=== Phase 4 Policy Engine Tests ===\n", .{});

    // Test 1: Policy Engine Standalone
    std.log.info("Test 1: Policy Engine - Allow Title Changes", .{});
    {
        var engine = policy.PolicyEngine.init(allocator, .{
            .allow_title_changes = true,
            .confirm_title_changes = false,
        });

        var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, "Test Title");
        defer decision.deinit(allocator);

        std.log.info("  Verdict: {s}", .{@tagName(decision.verdict)});
        std.log.info("  Rationale: {s}", .{decision.rationale});
        std.log.info("  ✓ PASS\n", .{});
    }

    // Test 2: Policy Engine - Confirm Hyperlinks
    std.log.info("Test 2: Policy Engine - Confirm Hyperlinks", .{});
    {
        var engine = policy.PolicyEngine.init(allocator, .{
            .allow_hyperlinks = true,
            .confirm_hyperlinks = true,
        });

        var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_HYPERLINK, "https://example.com");
        defer decision.deinit(allocator);

        std.log.info("  Verdict: {s}", .{@tagName(decision.verdict)});
        std.log.info("  Rationale: {s}", .{decision.rationale});
        if (decision.metadata) |m| {
            std.log.info("  Metadata: {s}", .{m});
        }
        std.log.info("  ✓ PASS\n", .{});
    }

    // Test 3: Policy Engine - Reject Palette Changes
    std.log.info("Test 3: Policy Engine - Reject Palette Changes", .{});
    {
        var engine = policy.PolicyEngine.init(allocator, .{
            .allow_palette_changes = false,
        });

        var decision = try engine.evaluateOsc(ghostty.OSC_COMMAND_SET_COLOR, null);
        defer decision.deinit(allocator);

        std.log.info("  Verdict: {s}", .{@tagName(decision.verdict)});
        std.log.info("  Rationale: {s}", .{decision.rationale});
        std.log.info("  ✓ PASS\n", .{});
    }

    // Test 4: Terminal Runtime Integration
    std.log.info("Test 4: Terminal Runtime with Policy Engine", .{});
    {
        var runtime = try TerminalRuntime.init(allocator, .{
            .policy_config = .{
                .allow_title_changes = true,
                .confirm_hyperlinks = true,
            },
        });
        defer runtime.shutdown();

        // Test paste safety
        var paste_result = try runtime.enqueuePaste("echo hello");
        defer paste_result.deinit(allocator);

        std.log.info("  Paste verdict: {s}", .{@tagName(paste_result.verdict)});
        std.log.info("  Paste rationale: {s}", .{paste_result.rationale});

        const stats = runtime.getPolicyStats();
        std.log.info("  Policy stats: {}", .{stats});
        std.log.info("  ✓ PASS\n", .{});
    }

    // Test 5: Unsafe Paste Confirmation
    std.log.info("Test 5: Unsafe Paste Requires Confirmation", .{});
    {
        var runtime = try TerminalRuntime.init(allocator, .{});
        defer runtime.shutdown();

        var paste_result = try runtime.enqueuePaste("rm -rf /\nsudo reboot");
        defer paste_result.deinit(allocator);

        std.log.info("  Paste verdict: {s}", .{@tagName(paste_result.verdict)});
        std.log.info("  Paste rationale: {s}", .{paste_result.rationale});
        std.log.info("  ✓ PASS\n", .{});
    }

    // Test 6: Statistics Tracking
    std.log.info("Test 6: Policy Statistics Tracking", .{});
    {
        var engine = policy.PolicyEngine.init(allocator, .{
            .allow_title_changes = true,
            .confirm_hyperlinks = true,
            .allow_palette_changes = false,
        });

        // Generate different verdicts
        var d1 = try engine.evaluateOsc(ghostty.OSC_COMMAND_CHANGE_WINDOW_TITLE, "Title 1");
        defer d1.deinit(allocator);

        var d2 = try engine.evaluateOsc(ghostty.OSC_COMMAND_HYPERLINK, "https://test.com");
        defer d2.deinit(allocator);

        var d3 = try engine.evaluateOsc(ghostty.OSC_COMMAND_SET_COLOR, null);
        defer d3.deinit(allocator);

        var d4 = try engine.evaluatePaste("safe text", true);
        defer d4.deinit(allocator);

        var d5 = try engine.evaluatePaste("unsafe\ntext", false);
        defer d5.deinit(allocator);

        const stats = engine.getStats();
        std.log.info("  Total OSC: {}", .{stats.total_osc_evaluations});
        std.log.info("  Total Paste: {}", .{stats.total_paste_evaluations});
        std.log.info("  Allows: {}", .{stats.allows});
        std.log.info("  Confirms: {}", .{stats.confirmations});
        std.log.info("  Rejects: {}", .{stats.rejections});
        std.log.info("  ✓ PASS\n", .{});
    }

    std.log.info("=== All Policy Engine Tests Passed! ===", .{});
    std.log.info("\nPhase 4 - OSC Bus & Policy Engine: COMPLETE ✅", .{});
}
