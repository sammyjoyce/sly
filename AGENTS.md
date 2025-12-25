# sly - AI Agent Guidelines

## Commands (NixOS: run inside `nix develop`)
- **Build**: `zig build -Doptimize=ReleaseSafe`
- **Test all**: `zig build test`
- **Test single module**: `zig build test --test-filter "test_name"` (or run specific: `zig build test-ghostty`)
- **Format**: `zig fmt src/ build.zig`
- **Check (fast)**: `zig build check`
- **Run**: `./zig-out/bin/sly "query"` or `SLY_PROVIDER=echo ./zig-out/bin/sly "test"`
- **Plan**: `./zig-out/bin/sly plan --query "your query" --context "optional context"`
- **Test VT parsing**: `./zig-out/bin/sly feedbytes --input "Hello\x1b[1;31mWorld\x1b[0m" --snapshot`

## Architecture
- `src/main.zig` - Entry point, CLI handling
- `src/sly.zig` - Core logic, shell detection/integration
- `src/providers.zig` - AI provider implementations (Anthropic, Gemini, OpenAI, Ollama)
- `src/cli.zig` - Argument parsing (uses argzon)
- `src/terminal_runtime.zig` - libghostty-based terminal emulator (VT parsing, SGR/OSC, snapshots)
- `src/policy_engine.zig` - Security policy engine for OSC commands and paste validation
- `src/command_planner.zig` - CommandPlan schema, JSON parsing, plan execution with audit
- `src/context.zig` - Environment context gathering (shell, git, project type)
- `src/libghostty.zig` - Ghostty terminal library bindings (@cImport wrapper)
- `vendor/ghostty/` - Vendored ghostty-vt library
- `lib/` and `src/*.plugin.{zsh,sh}` - Shell plugins (zsh, bash) - src/ versions embedded via @embedFile

## Shell Integration UX
1. User types `# natural language query` and presses Enter
2. Plugin captures query and context, calls `sly plan --query --context`
3. AI generates CommandPlan JSON with command/args/metadata
4. Plugin parses JSON and replaces buffer with command
5. User presses Enter again to execute

## Code Style
- **Language**: Zig 0.15.2+ with standard library idioms
- **Errors**: Return error unions, use `errdefer` for cleanup
- **Memory**: Use allocator pattern, `defer`/`errdefer` for deallocation
- **Naming**: snake_case for functions/variables, PascalCase for types
- **No comments** unless code is complex and requires context
