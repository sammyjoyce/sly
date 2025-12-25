# sly × libghostty Terminal Replatform Specification

## Vision
Rebuild sly as a libghostty-native co-pilot where every visible byte, key event, OSC mutation, and policy decision flows through the Ghostty virtual terminal stack. The refactor produces a deterministic runtime capable of running identically on native shells, remote sessions, and browser/Wasm hosts while orchestrating AI-assisted command planning.

## Experience Contract (Hash Flow)
1. **Hash trigger** – When the first non-whitespace character in the line is `#`, the Terminal Runtime switches the session into natural-language capture mode and pauses PTY passthrough.
2. **Natural language input** – The request buffer is echoed locally while the Conversation Orchestrator gathers libghostty snapshots, repo metadata, and policy hints to assemble a provider prompt.
3. **First Enter (LLM render)** – The response is validated into a declarative plan, re-encoded as shell bytes via `ghostty_key_encoder_encode`, and replaces the user buffer inside the libghostty viewport without executing.
4. **Second Enter (execution)** – The approved command stream is injected into the PTY through the Terminal Runtime; osc/sgr output from the shell is immediately looped back into libghostty for consistent state.

Every user surface (CLI, bash/zsh plugin, multiplexers, browser clients) MUST implement this four-step handshake with identical timing semantics.

## Capability Targets
- libghostty is the single terminal engine; no escape-sequence parsing outside the library.
- Scrollback, palette, hyperlink, title, cursor, and OSC metadata originate from `ghostty_vt` state snapshots.
- Kitty Keyboard Protocol (`GHOSTTY_KITTY_KEY_ALL`) is enabled session-wide with runtime toggles for cursor/keypad modes and Option-as-Alt behavior.
- Paste data is gated by `ghostty_paste_is_safe` with user-visible policy outcomes.
- Providers always produce structured plans (`command`, `arguments`, `paste_policy`, `confirm_mode`, `expectations`, `failure_signals`) before any PTY write.
- Observability includes per-call `GhosttyResult`, allocator provenance, and snapshot hashes for deterministic replay.

## Architecture Overview
```
Provider -> Conversation Orchestrator -> Command Planner -> Terminal Runtime (libghostty)
                                                    |                      |
                                            Snapshots & Policies        Shell Bridge (PTY)
```

### Terminal Runtime (libghostty Core)
- Wraps `ghostty/vt.h`, `ghostty/vt/sgr.h`, `ghostty/vt/osc.h`, `ghostty/vt/key/event.h`, `ghostty/vt/key/encoder.h`, `ghostty/vt/paste.h`, and `ghostty/vt/allocator.h` behind a Zig facade.
- Accepts a caller-supplied `GhosttyAllocator` or defaults to NULL for the built-in allocator. All handles (`GhosttySgrParser`, `GhosttyOscParser`, `GhosttyKeyEncoder`, pooled `GhosttyKeyEvent`s) are created in `init(SessionParams)` and owned for the lifetime of the shell session.
- Exposes: `init`, `resize`, `reset`, `shutdown`, `feedBytes`, `injectKey`, `enqueuePaste`, `drainOsc`, `snapshot`, and `metrics` APIs.
- Maintains scrollback, cursor, viewport, hyperlink metadata, palette overrides, and OSC terminator data exclusively through libghostty state.

### Input Path & Command Gating
- All input—user keystrokes, planner replays, automation shortcuts—flow through `GhosttyKeyEvent` handles mutated via `ghostty_key_event_set_action`, `ghostty_key_event_set_key`, `ghostty_key_event_set_mods`, `ghostty_key_event_set_utf8`, and `ghostty_key_event_set_unshifted_codepoint`.
- Encoding uses a dedicated buffer that expands when `ghostty_key_encoder_encode` returns `GHOSTTY_OUT_OF_MEMORY`. Kitty protocol flags default to `GHOSTTY_KITTY_KEY_ALL`, with configuration via `ghostty_key_encoder_setopt` for cursor/keypad modes, `GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX`, and `GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT`.
- The Command Planner synthesizes keystreams from declarative plans, tagging each emission with hashes for audit. User edits between Enter presses are captured through the same encoder to guarantee deterministic logging.

### Output Path, Styling, and Snapshots
- PTY output bytes stream into `feedBytes`, which dispatches them to libghostty and processes resulting render state.
- SGR sequences: parameters are loaded with `ghostty_sgr_set_params`; attributes are enumerated via `ghostty_sgr_next` and materialized into framebuffer cells carrying `GhosttySgrAttributeTag`, `GhosttyColorPaletteIndex`, RGB overrides (via `ghostty_color_rgb_get`), underline metadata, and unknown attribute payloads using `ghostty_sgr_unknown_full/partial`.
- OSC sequences: bytes are pumped through `ghostty_osc_next` and finalized with `ghostty_osc_end`. Command classification relies on `ghostty_osc_command_type`, and payload extraction uses `ghostty_osc_command_data` (e.g., titles via `GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR`). Terminators (BEL vs ST) are preserved per command for symmetric replies.
- Snapshots expose:
  - Viewport tiles with text, attributes, hyperlink IDs, palette indexes.
  - Cursor info (row, col, origin mode, visible state).
  - Scrollback pages with delta compression.
  - OSC event ledger plus policy verdicts.
  - Hashes capturing VT state, allowing providers to request diffs.

### Conversation Orchestrator & Providers
- Builds prompts containing snapshot summaries, git context, cwd metadata, policy hints, and user instructions while respecting secrecy filters for OSC-derived data (e.g., clipboard).
- Supports Anthropic, OpenAI, Gemini, Ollama, and offline echo providers. Each adapter validates responses against the declarative plan schema, retries on schema errors, and emits telemetry for latency, token usage, and validation failures.
- Encodes provider instructions with deterministic JSON payloads, reusing the existing HTTP stack but isolating provider logic from libghostty internals.

### Command Planner
- Consumes validated plans and replays them inside the Terminal Runtime before any PTY write.
- Observes snapshots before/after each plan stage, compares against `expectations` and `failure_signals`, and classifies the plan as `success`, `degraded`, or `blocked`.
- Applies policy tiers (auto, confirm, reject). Auto-run plans still require the dual-enter handshake unless the policy explicitly grants bypass rights.

### Shell Bridge & Surfaces
- Manages PTY creation, window resizing, and byte forwarding. Shell output is immediately redirected into `feedBytes`; approved command streams are written back to the PTY only after the second Enter.
- Plugins for bash/zsh intercept the hash-prefixed line, pause shell editing, and display planner status (spinner, validation messages) while waiting for approvals.
- GUI/Wasm clients allocate libghostty handles using `ghostty_wasm_alloc_*` helpers (`ghostty_wasm_alloc_opaque`, `ghostty_wasm_alloc_u16_array`, `ghostty_wasm_alloc_sgr_attribute`, etc.) so the browser runtime mirrors native semantics.

### Paste & Policy Controls
- Before injection, paste buffers are checked with `ghostty_paste_is_safe`. Unsafe buffers trigger policy escalation: prompt the user, wrap with bracketed paste identifiers only after consent, and log the verdict.
- Planner outputs declare `paste_policy` hints (`auto`, `needs_confirm`, `never`). Runtime enforcement happens inside `enqueuePaste`, ensuring that no bytes bypass libghostty validation.

### Observability & Telemetry
- Every libghostty call logs `{fn, GhosttyResult, duration, allocator_id}`. Failures for `GHOSTTY_OUT_OF_MEMORY` or `GHOSTTY_INVALID_VALUE` bubble up as structured events with retry/circuit-breaker hooks.
- Snapshots, OSC events, paste decisions, and plan outcomes are hashed and emitted to the Observability Spine for dashboards and replay harnesses.
- Deterministic replay harnesses feed recorded PTY byte streams through the runtime and assert snapshot hashes across native and Wasm builds.

### Security & Policy Guardrails
- Hash gating is the sole entry point for automation; other shell input is passed directly to the PTY with no libghostty interception.
- OSC 52 clipboard writes, palette changes, or hyperlink injections are classified and either allowed, confirmed, or blocked by policy modules before surfacing to the user.
- Planner audits store `{plan_id, hash, snapshot_before, snapshot_after, osc_events, paste_verdicts}` for postmortems.

### Deliverables
- Terminal Runtime Zig crate exposing the APIs above for native and Wasm targets.
- Command Planner and declarative plan schema with validation utilities.
- Updated shell plugins/CLI surfaces implementing the dual-enter UX and streaming orchestrator status.
- Observability pipeline (logs, metrics, replay harnesses) capturing libghostty interactions and policy outcomes.

---

## Implementation Notes (Phases 0-1 Complete)

### Actual Build System Architecture

**Zig Build Graph:**
```
zig build
    ├── lib-ghostty (Step.Compile)
    │   ├── vendor/ghostty/src/main_vt.zig (entry point)
    │   └── outputs: libghostty-vt.so
    └── sly (Step.Compile)
        ├── src/main.zig
        ├── linkLibrary(libghostty-vt)
        ├── linkLibC()
        └── addIncludePath("vendor/ghostty/include")
```

**Key Build Decisions:**
- Uses `std.Build.Step.Compile.createSharedLibrary()` for libghostty-vt to enable WASM linking later
- `b.path()` API ensures cross-platform path compatibility
- No external build tools (make, cmake, bash) required
- Test step separation: `test-ghostty` runs integration tests independently

### C API Binding Pattern

**File Structure:**
```zig
// src/libghostty.zig - All C imports in one place
pub const c = @cImport({
    @cInclude("ghostty/vt.h");
    @cInclude("ghostty/vt/key/event.h");
    @cInclude("ghostty/vt/key/encoder.h");
    // ... other headers
});

// Zig wrappers for C opaque types
pub const GhosttyKeyEncoder = opaque {
    pub fn create(alloc: ?*c.GhosttyAllocator) !*GhosttyKeyEncoder { ... }
    pub fn destroy(self: *GhosttyKeyEncoder) void { ... }
};

// src/terminal_runtime.zig - High-level Zig API
pub const TerminalRuntime = struct {
    allocator: std.mem.Allocator,
    encoder: *libghostty.GhosttyKeyEncoder,
    
    pub fn init(params: InitParams) !TerminalRuntime { ... }
    pub fn shutdown(self: *TerminalRuntime) void { ... }
};
```

**Type Safety Pattern:**
- All C pointers wrapped in Zig opaque types
- Result codes (`GhosttyResult`) converted to Zig errors (`!void`)
- Const correctness maintained through Zig type system

### Actual Test Coverage (Phase 1)

**Integration Tests in `src/test_ghostty.zig`:**
1. **Key Encoder Creation**
   - Verifies `ghostty_key_encoder_create()` succeeds
   - Validates Kitty keyboard protocol flags (`GHOSTTY_KITTY_KEY_ALL`)
   
2. **Key Event Encoding**
   - Enter key: Expected encoding `1b5b313375` (5 bytes)
   - Ctrl+C: No encoding (traditional ASCII 0x03)
   - Validates encoder output buffer management
   
3. **Terminal Lifecycle**
   - Initialization with custom params (80×24, scrollback 10000)
   - Resize operation (120×40)
   - Clean shutdown without leaks

**Coverage Gaps (Phase 2 Required):**
- SGR parser: Headers imported, not yet tested
- OSC parser: Headers imported, not yet tested  
- PTY output processing: Stubbed
- Snapshot generation: Stubbed

### Environment Requirements

**Exact Versions:**
- Zig: 0.15.2 (enforced in `build.zig.zon` and `flake.nix`)
- libcurl: System version (linked via pkg-config)
- ghostty: Vendored at `vendor/ghostty/` (specific commit in repo)

**Nix Flake Dev Shell Provides:**
- zig (version 0.15.2)
- pkg-config
- curl (libcurl headers)
- stdenv (C compiler for libghostty-vt)

**Direnv Integration:**
```sh
# .envrc
use flake
```
Automatically loads exact Zig version when entering directory.

### Phase 2 Readiness Checklist

**Blocked on Documentation:**
- [ ] PTY byte stream format from libghostty-vt
- [ ] SGR parser lifecycle (create/feed/iterate/destroy)
- [ ] OSC parser state machine diagram
- [ ] Snapshot data structure expectations

**Ready to Implement:**
- [x] Build system can link libghostty-vt ✓
- [x] C API bindings expose required headers ✓
- [x] TerminalRuntime structure in place ✓
- [x] Test infrastructure available ✓
- [ ] PTY recording tools for golden tests
- [ ] Example PTY fixtures with known SGR/OSC sequences

**Next Concrete Steps:**
1. Study `ghostty/vt.h` API for PTY byte ingestion
2. Examine SGR parser example from ghostty source
3. Create minimal test: feed ANSI escape sequence, read SGR attributes
4. Document actual libghostty-vt API behavior (not just spec)
