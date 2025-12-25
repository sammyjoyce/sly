# sly - AI Agent Guidelines

## Commands (NixOS: run inside `nix develop`)
- **Build**: `zig build -Doptimize=ReleaseSafe`
- **Test all**: `zig build test`
- **Test single module**: `zig build test --test-filter "test_name"` (or run specific: `zig build test-ghostty`)
- **Format**: `zig fmt src/ build.zig`
- **Check (fast)**: `zig build check`
- **Run**: `./zig-out/bin/sly "query"` or `SLY_PROVIDER=echo ./zig-out/bin/sly "test"`

## Architecture
- `src/main.zig` - Entry point, CLI handling
- `src/sly.zig` - Core logic, shell detection/integration
- `src/providers.zig` - AI provider implementations (Anthropic, Gemini, OpenAI, Ollama)
- `src/cli.zig` - Argument parsing (uses argzon)
- `src/terminal_runtime.zig`, `src/policy_engine.zig`, `src/pty_manager.zig` - Terminal/PTY handling
- `src/libghostty.zig` - Ghostty terminal library bindings
- `vendor/ghostty/` - Vendored ghostty-vt library
- `lib/` - Shell plugins (zsh, bash)

## Code Style
- **Language**: Zig 0.15.2+ with standard library idioms
- **Errors**: Return error unions, use `errdefer` for cleanup
- **Memory**: Use allocator pattern, `defer`/`errdefer` for deallocation
- **Naming**: snake_case for functions/variables, PascalCase for types
- **No comments** unless code is complex and requires context
