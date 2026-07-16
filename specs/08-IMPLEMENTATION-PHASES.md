# Implementation Phases

## Overview

This document outlines the phased implementation plan for rebuilding sly on libghostty-vt. The plan is divided into five phases, each building on the previous, with clear milestones and deliverables.

## Phase Summary

| Phase | Focus | Duration | Key Deliverables |
|-------|-------|----------|------------------|
| 1 | Foundation | 2 weeks | Terminal runtime skeleton, libghostty bindings |
| 2 | Terminal State | 2 weeks | Framebuffer, SGR/OSC parsing, snapshots |
| 3 | Input & Paste | 2 weeks | Key encoding, paste validation, bracketed paste |
| 4 | Policy Engine | 2 weeks | OSC policies, security model, statistics |
| 5 | Integration | 2 weeks | Shell plugins, UX flow, command planner |

## Phase 1: Foundation

### Objectives

- Establish libghostty-vt integration
- Create Terminal Runtime skeleton
- Set up build system

### Tasks

#### 1.1 libghostty Integration

```
□ Clone ghostty repository into vendor/ghostty
□ Create Zig bindings (src/libghostty.zig)
  - Import C headers via @cImport
  - Define type aliases for common types
  - Create result checking helpers
□ Update build.zig to build libghostty-vt
  - Add lib-ghostty build step
  - Configure library linking
  - Set up include paths
```

#### 1.2 Terminal Runtime Skeleton

```
□ Create src/terminal_runtime.zig
  - Define InitParams structure
  - Implement init() and shutdown()
  - Create key encoder instance
  - Placeholder methods for future phases
□ Write unit tests for lifecycle management
□ Document API surface
```

#### 1.3 Build System

```
□ Configure Nix flake for dependencies
□ Set up direnv for development environment
□ Create test targets (zig build test)
□ Verify cross-platform builds (Linux, macOS)
```

### Deliverables

- [ ] `src/libghostty.zig` - Zig bindings to C API
- [ ] `src/terminal_runtime.zig` - Runtime skeleton
- [ ] `build.zig` - Updated build configuration
- [ ] `flake.nix` - Nix development environment
- [ ] Passing unit tests

### Milestone: Runtime Initialization

```zig
// This should work
var runtime = try TerminalRuntime.init(allocator, .{
    .cols = 80,
    .rows = 24,
});
defer runtime.shutdown();
```

---

## Phase 2: Terminal State

### Objectives

- Implement framebuffer model
- Parse SGR (styling) sequences
- Parse OSC (operating system command) sequences
- Create snapshot system

### Tasks

#### 2.1 Framebuffer

```
□ Define Cell structure with styling attributes
□ Create 2D grid storage (ArrayList of ArrayList)
□ Implement cursor movement
  - Write character at cursor
  - Handle newline, carriage return, tab, backspace
□ Implement scrolling when cursor exceeds viewport
□ Write tests for cursor operations
```

#### 2.2 SGR Parser Integration

```
□ Initialize SGR parser in Terminal Runtime
□ Implement processSgrSequence()
  - Parse CSI parameters
  - Map to Cell attributes
□ Handle color codes (8, 256, RGB)
□ Handle text attributes (bold, italic, underline)
□ Write tests for SGR parsing
```

#### 2.3 OSC Parser Integration

```
□ Initialize OSC parser in Terminal Runtime
□ Implement processOscCommand()
  - Feed bytes to parser
  - Extract command type and data
□ Create OscEvent structure
□ Store events in runtime for snapshot
□ Write tests for OSC parsing
```

#### 2.4 Snapshot System

```
□ Define Snapshot structure
□ Implement snapshot() method
  - Deep copy framebuffer
  - Copy OSC events
  - Compute content hash
□ Implement formatSnapshotForPrompt()
□ Write tests for snapshot creation
```

### Deliverables

- [ ] Framebuffer with cursor and scrolling
- [ ] SGR parsing and cell styling
- [ ] OSC parsing and event collection
- [ ] Snapshot creation with hash computation
- [ ] formatSnapshotForPrompt() for LLM context

### Milestone: VT Sequence Processing

```zig
var runtime = try TerminalRuntime.init(allocator, .{});
defer runtime.shutdown();

// Feed styled output
try runtime.feedBytes("\x1b[1;31mRed Bold\x1b[0m Normal");
try runtime.feedBytes("\x1b]2;Window Title\x07");

// Capture state
var snap = try runtime.snapshot(.{});
defer snap.deinit(allocator);

// Verify content
assert(snap.framebuffer[0][0].bold == true);
assert(snap.framebuffer[0][0].fg_color == 1);  // Red
assert(snap.osc_events.len == 1);
```

---

## Phase 3: Input & Paste

### Objectives

- Implement key encoding with Kitty protocol
- Create paste validation and bracketed paste
- Build injectKey() and enqueuePaste() methods

### Tasks

#### 3.1 Key Encoding

```
□ Create key encoder in runtime init
□ Implement injectKey() method
  - Create key event
  - Set action, key, modifiers
  - Encode to escape sequence
  - Return owned bytes
□ Implement setKeyEncoderOptions()
  - Cursor key application mode
  - Alt ESC prefix
  - Kitty protocol flags
□ Write tests for key encoding
```

#### 3.2 Key Event Handling

```
□ Map common key codes (Enter, Tab, arrows, etc.)
□ Handle modifier combinations
□ Support Kitty keyboard protocol
  - DISAMBIGUATE flag
  - REPORT_EVENTS flag
□ Handle special cases (Ctrl+C returns empty)
```

#### 3.3 Paste Validation

```
□ Integrate ghostty_paste_is_safe()
□ Create PasteVerdict enum (safe_auto, unsafe_needs_confirm, rejected)
□ Create PasteResult structure
□ Implement enqueuePaste() method
  - Check safety with libghostty
  - Apply policy decision
  - Wrap in bracketed paste
□ Write tests for paste safety
```

#### 3.4 Bracketed Paste

```
□ Implement wrapBracketedPaste()
  - Add ESC[200~ start marker
  - Add ESC[201~ end marker
□ Handle edge cases
  - Empty paste
  - Special characters
  - Embedded escape sequences
```

### Deliverables

- [ ] injectKey() with Kitty protocol support
- [ ] setKeyEncoderOptions() for runtime configuration
- [ ] enqueuePaste() with safety validation
- [ ] Bracketed paste wrapping
- [ ] Full test coverage

### Milestone: Input Synthesis

```zig
// Key encoding
const enter_seq = try runtime.injectKey(
    ghostty.KEY_ACTION_PRESS,
    13,  // Enter
    0,   // No modifiers
);
// Result: "\r" or ESC[13u

// Paste with safety check
var paste_result = try runtime.enqueuePaste("echo hello");
defer paste_result.deinit(allocator);

assert(paste_result.verdict == .safe_auto);
assert(std.mem.startsWith(u8, paste_result.bytes.?, "\x1b[200~"));
```

---

## Phase 4: Policy Engine

### Objectives

- Build policy engine for OSC commands
- Implement configurable security policies
- Add statistics and observability

### Tasks

#### 4.1 Policy Engine Core

```
□ Create src/policy_engine.zig
□ Define PolicyVerdict enum
□ Define PolicyDecision structure
□ Define PolicyConfig with all options
□ Implement PolicyEngine.init()
```

#### 4.2 OSC Policy Evaluation

```
□ Implement evaluateOsc() method
  - Handle each OSC command type
  - Apply configuration rules
  - Return decision with rationale
□ Handle unknown commands with default policy
□ Track statistics (allows, confirms, rejects)
```

#### 4.3 Paste Policy Evaluation

```
□ Implement evaluatePaste() method
  - Check libghostty safety result
  - Apply policy rules
  - Generate rationale
□ Track paste evaluations in statistics
```

#### 4.4 Integration with Terminal Runtime

```
□ Add PolicyEngine to TerminalRuntime
□ Call policy engine in processOscCommand()
□ Store policy decisions in OscEvent
□ Add getPolicyStats() method
```

#### 4.5 Configuration Presets

```
□ Define DEFAULT_POLICY
□ Define STRICT_POLICY
□ Define PERMISSIVE_POLICY
□ Environment variable overrides
```

### Deliverables

- [ ] `src/policy_engine.zig` with full implementation
- [ ] OSC command policies for all types
- [ ] Paste policy integration
- [ ] Statistics tracking
- [ ] Configuration presets and env var support

### Milestone: Security Policy

```zig
var engine = PolicyEngine.init(allocator, .{
    .allow_osc52 = true,
    .confirm_osc52 = true,
});

// Evaluate clipboard access
var decision = try engine.evaluateOsc(
    OSC_COMMAND_CLIPBOARD_CONTENTS,
    "secret data",
);
defer decision.deinit(allocator);

assert(decision.verdict == .confirm);
assert(std.mem.indexOf(u8, decision.rationale, "confirmation") != null);

// Check statistics
const stats = engine.getStats();
assert(stats.confirmations == 1);
```

---

## Phase 5: Integration

### Objectives

- Complete shell plugin integration
- Implement full UX flow
- Build command planner
- End-to-end testing

### Tasks

#### 5.1 Shell Plugins

```
□ Update lib/sly.plugin.zsh
  - Call sly plan instead of sly
  - Parse CommandPlan JSON
  - Handle errors gracefully
□ Update lib/bash-sly.plugin.sh
  - Same updates as zsh
□ Add context capture (history, buffer)
□ Test in real shell environments
```

#### 5.2 CLI Commands

```
□ Implement sly plan command
  - Accept --query and --context flags
  - Output CommandPlan JSON
□ Implement sly shell install
  - Detect shell type
  - Write plugin files
  - Optional rc file update
□ Update help and version output
```

#### 5.3 Command Planner

```
□ Create src/command_planner.zig
□ Define CommandPlan structure
□ Implement fromJson() parsing
□ Implement toJson() serialization
□ Implement plan execution with audit trail
  - Capture before/after snapshots
  - Track keystream hash
  - Validate expectations
```

#### 5.4 LLM Integration

```
□ Update system prompt for CommandPlan schema
□ Add retry logic for validation failures
□ Include terminal snapshot in context
□ Test with all providers
```

#### 5.5 UX Flow

```
□ Implement # trigger detection in plugins
□ Add spinner animation (zsh)
□ Buffer replacement with generated command
□ Error display with colors
```

### Deliverables

- [ ] Updated shell plugins for bash and zsh
- [ ] `sly plan` command with JSON output
- [ ] `sly shell install` command
- [ ] Command planner with audit trail
- [ ] Full UX flow implementation
- [ ] End-to-end tests

### Milestone: Complete UX Flow

```bash
# In zsh with plugin loaded
$ # list all PDF files modified this week
[spinner animation]
$ find . -name "*.pdf" -mtime -7
[user presses Enter to execute]
./docs/report.pdf
./downloads/invoice.pdf
$
```

---

## Testing Strategy

### Unit Tests

Each phase includes unit tests for new functionality:

```bash
# Run all tests
zig build test

# Run specific test file
zig build test -- --test-filter "terminal runtime"
```

### Integration Tests

```bash
# Test libghostty integration
zig build test-ghostty

# Test with echo provider
SLY_PROVIDER=echo sly plan --query "test"
```

### End-to-End Tests

```bash
# Test shell integration (manual)
source lib/sly.plugin.zsh
# list files
# [should see command replacement]
```

---

## Documentation Plan

### Per-Phase Documentation

| Phase | Documentation |
|-------|---------------|
| 1 | API reference for libghostty bindings |
| 2 | Terminal state model documentation |
| 3 | Key encoding and paste safety guide |
| 4 | Security policy configuration guide |
| 5 | User guide and shell integration docs |

### Final Documentation

- [ ] README.md update with new architecture
- [ ] CHANGELOG.md with breaking changes
- [ ] docs/libghostty-integration.md
- [ ] specs/ directory with all specifications

---

## Risk Mitigation

### Technical Risks

| Risk | Mitigation |
|------|------------|
| libghostty API changes | Pin to specific commit, test on updates |
| Performance regression | Benchmark key operations, optimize hot paths |
| Shell compatibility | Test on bash 4.x, 5.x, zsh 5.x |
| Provider API changes | Abstract provider layer, version lock |

### Schedule Risks

| Risk | Mitigation |
|------|------------|
| Phase dependencies | Clear milestones, early integration |
| Scope creep | Fixed scope per phase, defer enhancements |
| Testing gaps | Write tests alongside implementation |

---

## Success Criteria

### Phase 1 Complete When

- [ ] Runtime initializes without errors
- [ ] Key encoder created and functional
- [ ] All Phase 1 unit tests pass
- [ ] Build works on Linux and macOS

### Phase 2 Complete When

- [ ] Framebuffer correctly renders text
- [ ] SGR sequences apply correct styling
- [ ] OSC events are captured
- [ ] Snapshots include all state

### Phase 3 Complete When

- [ ] Key encoding produces correct sequences
- [ ] Kitty protocol flags work correctly
- [ ] Paste safety detection accurate
- [ ] Bracketed paste wrapping correct

### Phase 4 Complete When

- [ ] All OSC types have policy rules
- [ ] Statistics accurately tracked
- [ ] Configuration presets work
- [ ] Policy decisions logged

### Phase 5 Complete When

- [ ] Shell plugins work in bash and zsh
- [ ] UX flow matches specification
- [ ] End-to-end tests pass
- [ ] Documentation complete

---

## Post-Launch

### Immediate (Month 1)

- [ ] Collect user feedback
- [ ] Fix critical bugs
- [ ] Performance tuning

### Short-term (Months 2-3)

- [ ] Fish shell support
- [ ] Additional LLM providers
- [ ] History-based suggestions

### Long-term (Months 4+)

- [ ] Interactive refinement
- [ ] Multi-command pipelines
- [ ] Plugin system for extensions
