# libghostty Replatform Design Decisions

## Document Purpose

This document captures the architectural decisions and their rationale for the sly × libghostty integration. Each decision includes implementation implications and lessons learned during Phases 0-1.

## 1. Single Terminal Authority
- **Decision**: libghostty-vt governs every byte of terminal state—rendering, scrollback, OSC, SGR, input encoding, and paste validation. No alternate parsers or shims exist.
- **Rationale**: `ghostty_vt` already understands modern escape semantics, Kitty keyboard features, and OSC terminators; duplicating this logic would reintroduce nondeterminism.
- **Implications**: All subsystems (planner, shell bridge, WASM client) operate through the `TerminalRuntime` facade; debugging relies on libghostty telemetry rather than ad-hoc ANSI inspection.

## 2. Hash-Gated Dual-Enter Flow
- **Decision**: Automation is only reachable via the `#` trigger followed by the dual Enter contract. The runtime enforces this regardless of client surface.
- **Rationale**: Aligns with the mandated UX and guarantees intentional execution.
- **Implications**: Shell plugins intercept hash-prefixed lines, pause PTY writes, and resume only when the planner and policy engine signal approval after the second Enter.

## 3. Session-Scoped TerminalRuntime Object
- **Decision**: Each shell session owns a long-lived `TerminalRuntime` containing the `GhosttyAllocator`, VT handle, `GhosttySgrParser`, `GhosttyOscParser`, `GhosttyKeyEncoder`, and pools of `GhosttyKeyEvent` objects.
- **Rationale**: Persistent handles make reflow, scrollback, and OSC histories reliable and minimize allocator churn.
- **Implications**: Lifecycle APIs (`init`, `resize`, `reset`, `shutdown`) are mandatory and must return detailed `GhosttyResult` codes for observability.

## 4. Kitty Keyboard Protocol Everywhere
- **Decision**: Encoders enable `GHOSTTY_KITTY_KEY_ALL` by default, with runtime toggles for cursor/keypad application modes, `GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX`, `GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK`, and `GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT`.
- **Rationale**: Rich key metadata is essential for deterministic plan replay, shortcut telemetry, and accessibility.
- **Implications**: Input buffers must accommodate longer escape sequences; telemetry logs encoder options per session.

## 5. Declarative Command Plans
- **Decision**: Providers output structured plans (`command`, `args`, `env`, `paste_policy`, `confirm_mode`, `expectations`, `failure_signals`). Free-form command text is never executed directly.
- **Rationale**: Schema validation is the primary defense against malformed LLM output.
- **Implications**: Conversation Orchestrator retries invalid schemas; Command Planner simulates plans in libghostty before PTY writes.

## 6. Snapshot Contract Based on SGR/OSC Semantics
- **Decision**: Snapshots capture framebuffer tiles with `GhosttySgrAttributeTag`s, palette indices, RGB overrides via `ghostty_color_rgb_get`, underline states from `GhosttySgrUnderline`, and any unknown attributes via `ghostty_sgr_unknown_full/partial`. OSC events are parsed via `ghostty_osc_command_type`/`ghostty_osc_command_data` and appended with policy verdicts.
- **Rationale**: Providers need semantically rich, stable context instead of raw escape sequences.
- **Implications**: Snapshot hashes become canonical references for plan prompts, audits, and replay tests.

## 7. Policy-Driven OSC Bus
- **Decision**: Every OSC command flows through a central policy bus. Titles, hyperlinks, palettes, and especially OSC 52 clipboard writes require explicit allow/confirm decisions before affecting user surfaces.
- **Rationale**: OSC payloads can leak data or hijack the UI; centralized policies provide consistent enforcement.
- **Implications**: OSC handlers preserve terminator bytes, attach verdict metadata, and feed observability streams.

## 8. Paste Safety Enforcement
- **Decision**: `ghostty_paste_is_safe` is executed on every paste buffer. Unsafe content (newlines, bracketed paste escapes) requires user confirmation and is logged even if approved.
- **Rationale**: Prevents injection attacks and ensures planner outputs cannot silently push multi-line scripts.
- **Implications**: Planner metadata may recommend policies, but runtime enforcement is final. Approved pastes are wrapped in bracketed paste fences before injection.

## 9. Wasm Parity via ghostty_wasm Helpers
- **Decision**: Browser/Electron builds allocate libghostty structures solely through `ghostty_wasm_alloc_*` utilities (`ghostty_wasm_alloc_opaque`, `ghostty_wasm_alloc_u8_array`, `ghostty_wasm_alloc_u16_array`, `ghostty_wasm_alloc_sgr_attribute`, etc.).
- **Rationale**: Keeps memory management safe and consistent with the native ABI while avoiding manual pointer arithmetic in JS.
- **Implications**: API surfaces remain identical across native and Wasm builds; snapshot hashes must match in parity tests.

## 10. Observability at the libghostty Boundary
- **Decision**: Every libghostty call logs `{fn, GhosttyResult, duration, allocator_id, parameters}`. Failures trigger retries or circuit breakers depending on severity.
- **Rationale**: Debugging escape-sequence issues requires visibility into the VT API interactions.
- **Implications**: Structured logs and metrics feed the Observability Spine; repeated `GHOSTTY_OUT_OF_MEMORY` or `GHOSTTY_INVALID_VALUE` events escalate alerts.

## 11. Deterministic Replay Harnesses
- **Decision**: PTY byte captures are replayed through `TerminalRuntime`, producing golden snapshot and OSC hashes. Commit hooks fail when hashes drift unexpectedly.
- **Rationale**: Guarantees behavioral stability across refactors, architectures, and Wasm builds.
- **Implications**: Fixtures include Kitty protocol events, multi-stage OSC commands, and paste sequences to stress libghostty parsers.

## 12. Policy-Driven Execution Approval
- **Decision**: Plans advance through policy tiers (`auto`, `confirm`, `reject`) based on snapshot heuristics (e.g., `GhosttySgrAttributeTag` combos signaling warnings), OSC types, and paste safety. Execution waits for the second Enter even when policies auto-approve.
- **Rationale**: Maintains user trust while keeping automation responsive.
- **Implications**: Planner outputs include policy hints, but runtime decisions override them. Telemetry stores policy provenance with each plan outcome.

---

## Lessons Learned (Phases 0-1)

### Build System Integration

**What Worked:**
- **Zig build system native**: Using `std.Build.Step.Compile` to build libghostty-vt directly in `build.zig` eliminated bash scripts and external build tools.
- **Automatic dependency ordering**: `sly.linkLibrary(libghostty_vt)` ensures libghostty builds before sly automatically.
- **Separate test step**: `zig build test-ghostty` allows isolated integration testing without running full test suite.

**Challenges:**
- **Header path resolution**: Required explicit `addIncludePath()` for `vendor/ghostty/include/` to expose C headers.
- **Library linking**: Must use `linkLibC()` before linking libghostty-vt to satisfy C runtime dependencies.
- **Cross-platform paths**: Used `b.path()` API for cross-platform compatibility instead of string concatenation.

**Recommendation:** Always use Zig's build system APIs (`b.path()`, `addIncludePath()`, `linkLibrary()`) rather than shell commands for maximum portability.

### C API Bindings Pattern

**What Worked:**
- **Single bindings file**: Consolidating all `@cImport` declarations in `src/libghostty.zig` created a clear API boundary.
- **Zig type wrappers**: Wrapping opaque C types (`GhosttyKeyEncoder`, `GhosttyKeyEvent`) in Zig structs prevented pointer errors.
- **Result enums**: Mapping `GhosttyResult` to Zig enums enabled compile-time exhaustive error handling.

**Challenges:**
- **Opaque type handling**: C `typedef struct ... *Handle;` patterns required careful `@ptrCast()` usage.
- **Optional allocator**: Null pointer handling for optional `GhosttyAllocator` required explicit checks.

**Recommendation:** Wrap all C API calls in typed Zig functions immediately to catch errors at compile time.

### Development Environment

**What Worked:**
- **Nix flake + direnv**: Automatic shell activation with exact Zig 0.15.2 version eliminated "works on my machine" issues.
- **Version pinning**: Enforcing Zig 0.15.2 in both `build.zig.zon` and `flake.nix` prevented API mismatches.
- **Vendored ghostty**: Using `vendor/ghostty/` allowed building without external dependencies on ghostty installation.

**Challenges:**
- **Nix hash calculation**: First build requires running twice to get correct vendor hash (documented in README).
- **Direnv trust**: Users must run `direnv allow` to enable automatic shell loading.

**Recommendation:** Document Nix hash workflow upfront and provide `.envrc` in repository for seamless onboarding.

### Testing Strategy

**What Worked:**
- **Integration over unit**: Testing through real libghostty C API (key encoding, result codes) caught actual integration issues.
- **Incremental verification**: Testing each API surface (encoder creation, event encoding) separately isolated failures.
- **Test artifacts**: Logging encoded key sequences (e.g., `1b5b313375` for Enter) provided debugging evidence.

**Challenges:**
- **Stub methods**: Testing stubs required logging-only assertions; full validation awaits Phase 2.
- **Lifecycle coupling**: Shutdown tests must carefully manage initialization order to avoid double-frees.

**Recommendation:** Phase 2 golden tests (PTY replay fixtures) will be critical for regression testing—start collecting real PTY sessions now.

### API Design

**What Worked:**
- **Separation of concerns**: `libghostty.zig` (C bindings) vs `terminal_runtime.zig` (Zig API) created clean abstraction layers.
- **InitParams struct**: Grouping configuration (cols, rows, scrollback, Kitty flags) in a single struct simplified initialization.
- **Method stubs with TODOs**: Placeholder implementations with clear TODO comments documented future work without blocking Phase 1.

**Challenges:**
- **Error propagation**: Deciding between `!void` (Zig errors) vs `GhosttyResult` (C enum) required consistency rules.
- **Resource ownership**: Clarifying whether TerminalRuntime or caller owns allocator/encoder required explicit documentation.

**Recommendation:** Use Zig errors (`!void`) at Zig API boundary, map from `GhosttyResult` internally for consistency.

### Phase Dependencies

**What Became Clear:**
- **Phase 2 is critical blocker**: Cannot implement snapshots, policy engine, or command planner without SGR/OSC parsing from Phase 2.
- **Phases 3 partial**: Key encoding worked ahead of schedule, but paste/policy parts blocked without Phase 2 OSC support.
- **Defer optimization**: Key event pools (Phase 3) are premature optimization until Phase 5 command replay shows actual allocation pressure.

**Recommendation:** Focus entirely on Phase 2 next—it unblocks Phases 4-5 and validates the entire libghostty integration.
