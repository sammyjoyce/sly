# sly - Shell AI Command Generator

A shell command generator written in Zig that converts natural language to shell commands using multiple AI providers.

## Project Structure

- `src/` - Zig source code
  - `main.zig` - Main entry point
- `lib/` - Shell integration plugins (zsh, bash)
- `build.zig` - Zig build configuration
- `.claude/` - Claude Code configuration
  - `settings.json` - Hooks configuration
  - `install_deps.sh` - Dependency installation script

## Build System

**Language**: Zig 0.15.2+

### Building on NixOS

NixOS stores libraries in the Nix store rather than standard system paths. Use one of these methods:

**Production build**:
```sh
nix build
# Binary available at: ./result/bin/sly
```

**Development build**:
```sh
nix develop
zig build -Doptimize=ReleaseSafe
# Binary available at: ./zig-out/bin/sly
```

### Building on other systems

**Build command**: `zig build -Doptimize=ReleaseSafe`

**Test command**: `zig build test`

**Format command**: `zig fmt src/ build.zig`

**Binary output**: `zig-out/bin/sly`

## Dependencies

- **Zig 0.15.2+** - Programming language and build system
- **libcurl** - HTTP client for API calls (system library, linked via pkg-config when available)
- **argzon** - Command-line argument parsing library (Zig dependency, fetched automatically)

The `.claude/install_deps.sh` script automatically installs these in Claude Code web environments.

## Key Features

- Multiple AI providers: Anthropic (Claude), Google (Gemini), OpenAI, Ollama
- Shell integration for zsh and bash
- Context-aware command generation (detects git status, project type, directory)
- Written in Zig for performance and minimal latency

## Development Workflow

### On NixOS:

1. **Enter dev shell**: `nix develop`
2. **Make changes** to source files in `src/`
3. **Format code**: `zig fmt src/ build.zig`
4. **Build**: `zig build -Doptimize=ReleaseSafe`
5. **Test**: `zig build test` (if tests exist)
6. **Run**: `./zig-out/bin/sly "your query"`

### On other systems:

1. **Make changes** to source files in `src/`
2. **Format code**: `zig fmt src/ build.zig`
3. **Build**: `zig build -Doptimize=ReleaseSafe`
4. **Test**: `zig build test` (if tests exist)
5. **Run**: `./zig-out/bin/sly "your query"`

## Testing

Test with the echo provider (offline mode) for development:
```sh
SLY_PROVIDER=echo ./zig-out/bin/sly "test query"
```

## Configuration

The tool uses environment variables for configuration:
- `SLY_PROVIDER` - AI provider selection
- `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY` - API keys
- `SLY_*_MODEL` - Model selection for each provider
- `SLY_PROMPT_EXTEND` - Custom system prompt extensions

See README.md for full environment variable reference.
