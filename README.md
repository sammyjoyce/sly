# sly

Shell AI command generator - convert natural language to shell commands using AI.

## Features

- **Multiple AI providers**: Anthropic (Claude), Google (Gemini), OpenAI (GPT), Ollama (local models)
- **Shell integration**: Type "# request" and press Enter in both zsh and bash
- **Context-aware**: Detects project type, git status, current directory
- **Fast**: Written in Zig 0.15.2+ with libcurl for minimal latency
- **Offline mode**: Echo provider for testing without API keys

## Installation

### Prerequisites

- Zig 0.15.2 or later
- libcurl development headers:
  - Ubuntu/Debian: `sudo apt-get install libcurl4-openssl-dev`
  - macOS: `brew install curl` (or use system libcurl)
  - Arch: `sudo pacman -S curl`

### Build from source

```sh
git clone https://codeberg.org/sam/sly.git
cd sly/
zig build -Doptimize=ReleaseSafe
```

Binary will be at `zig-out/bin/sly`.

### Add to PATH

```sh
export PATH="$PWD/zig-out/bin:$PATH"
```

Add to `~/.bashrc` or `~/.zshrc` to persist.

## Configuration

Set environment variables to configure providers and models:

```sh
# Choose provider (default: anthropic)
export SLY_PROVIDER=anthropic  # or gemini, openai, ollama, echo

# Anthropic (Claude)
export ANTHROPIC_API_KEY="sk-ant-..."
export SLY_ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"  # default

# Google Gemini
export GEMINI_API_KEY="..."
export SLY_GEMINI_MODEL="gemini-2.0-flash-exp"  # default

# OpenAI
export OPENAI_API_KEY="sk-..."
export SLY_OPENAI_MODEL="gpt-4o"  # default
export SLY_OPENAI_URL="https://api.openai.com/v1/chat/completions"  # default

# Ollama (local)
export SLY_OLLAMA_MODEL="llama3.2"  # default
export SLY_OLLAMA_URL="http://localhost:11434"  # default

# Custom system prompt extension
export SLY_PROMPT_EXTEND="Always use verbose flags"
```

## Usage

### CLI

```sh
# Direct invocation
sly "list all pdf files"
# Output: find . -name '*.pdf'

sly "show disk usage sorted by size"
# Output: du -sh * | sort -h
```

### zsh integration

Add to `~/.zshrc`:

```sh
source /path/to/sly/lib/sly.plugin.zsh
```

Then type:

```sh
# list all pdf files
# <press Enter>
# → Buffer becomes: find . -name '*.pdf'
```

Spinner animation shows progress. Press Enter again to execute, or edit first.

### bash integration

Add to `~/.bashrc`:

```sh
source /path/to/sly/lib/bash-sly.plugin.sh
```

Then type:

```sh
# list all pdf files
# <press Enter>
# → Buffer becomes: find . -name '*.pdf'
```

Press Enter again to execute, or edit first.

Alternative: Press `Ctrl-x a` to expand without executing.

## Development

### Run tests

```sh
zig build test
```

### Format code

```sh
zig fmt src/ build.zig
```

### Test with echo provider (offline)

```sh
SLY_PROVIDER=echo sly "test query"
# Output: echo 'test query'
```

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| SLY_PROVIDER | anthropic | AI provider: anthropic, gemini, openai, ollama, echo |
| ANTHROPIC_API_KEY | - | Anthropic API key (required for anthropic provider) |
| SLY_ANTHROPIC_MODEL | claude-3-5-sonnet-20241022 | Anthropic model name |
| GEMINI_API_KEY | - | Google Gemini API key (required for gemini provider) |
| SLY_GEMINI_MODEL | gemini-2.0-flash-exp | Gemini model name |
| OPENAI_API_KEY | - | OpenAI API key (required for openai provider) |
| SLY_OPENAI_MODEL | gpt-4o | OpenAI model name |
| SLY_OPENAI_URL | https://api.openai.com/v1/chat/completions | OpenAI API endpoint |
| SLY_OLLAMA_MODEL | llama3.2 | Ollama model name |
| SLY_OLLAMA_URL | http://localhost:11434 | Ollama server URL |
| SLY_PROMPT_EXTEND | - | Additional system prompt instructions |

## License

MIT - see LICENSE file

## Contributing

Patches welcome! Send to the mailing list or open an issue on Codeberg.
