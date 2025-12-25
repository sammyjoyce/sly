# sly Architecture Specification

## Overview

sly is a shell command generator that converts natural language queries into executable shell commands using AI. Built on **libghostty-vt** (the virtual terminal emulator library from the Ghostty project), sly provides deep terminal integration, enabling context-aware command generation with full understanding of terminal state.

## Vision

Transform the shell experience by enabling users to express intent in natural language and receive accurate, context-aware shell commands. By leveraging libghostty-vt's terminal emulation capabilities, sly understands the complete terminal context—including recent output, working directory, and shell state—to generate commands that are both accurate and safe.

## User Experience

### Core Interaction Flow

1. **Hash (#) key** - User presses `#` to enter natural language mode
2. **Natural language input** - User types their command request in plain English
3. **Enter key** - sly replaces the input buffer with the LLM-generated shell command
4. **Enter key again** - Execute the generated command

This two-step execution model ensures users always see and can modify the generated command before execution, maintaining control and safety.

### Example Session

```
$ # find all PDF files modified in the last week
[sly processes request...]
$ find . -name "*.pdf" -mtime -7
[user presses Enter to execute]
./documents/report.pdf
./downloads/invoice.pdf
```

## Design Principles

### 1. Terminal-Native Integration

sly operates as a native terminal extension, not a separate application. It integrates directly with the user's shell (bash, zsh, fish) through shell plugins that intercept the `#` key trigger.

### 2. Context Awareness

Every command generation request includes:
- Current working directory
- Recent terminal output (from framebuffer snapshots)
- OSC events (shell integration markers, directory changes)
- Git status when in a repository
- Project type detection (package.json, Cargo.toml, etc.)

### 3. Safety First

- **Preview before execution**: Commands are always shown before running
- **Paste validation**: Multi-line and potentially dangerous pastes require confirmation
- **Policy engine**: Configurable security policies for OSC commands and clipboard access
- **Bracketed paste**: All injected text uses terminal bracketed paste mode

### 4. Provider Agnostic

sly supports multiple LLM providers:
- Anthropic (Claude)
- Google (Gemini)
- OpenAI (GPT)
- Ollama (local models)
- Echo (offline testing mode)

### 5. Performance

Written in Zig with libcurl for minimal latency. The libghostty-vt library is compiled as a native shared library for optimal performance.

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                      Shell Plugins                               │
│                 (bash, zsh integration)                          │
├─────────────────────────────────────────────────────────────────┤
│                      sly CLI                                     │
│           (argument parsing, command dispatch)                   │
├─────────────────────────────────────────────────────────────────┤
│                    Command Planner                               │
│     (CommandPlan generation, validation, execution)              │
├─────────────────────────────────────────────────────────────────┤
│                   Terminal Runtime                               │
│  (libghostty-vt integration, state management, key encoding)     │
├─────────────────────────────────────────────────────────────────┤
│                    Policy Engine                                 │
│        (OSC filtering, paste validation, security)               │
├─────────────────────────────────────────────────────────────────┤
│                   Provider Adapters                              │
│        (Anthropic, Gemini, OpenAI, Ollama, Echo)                │
├─────────────────────────────────────────────────────────────────┤
│                   libghostty-vt                                  │
│     (Key Encoding, SGR Parsing, OSC Parsing, Paste Utils)        │
└─────────────────────────────────────────────────────────────────┘
```

## libghostty-vt Capabilities

The libghostty-vt library provides:

| Component | Purpose |
|-----------|---------|
| **Key Encoding** | Convert key events to terminal escape sequences (Kitty protocol) |
| **SGR Parser** | Parse Select Graphic Rendition (styling) sequences |
| **OSC Parser** | Parse Operating System Command sequences |
| **Paste Utilities** | Validate paste data safety (newlines, escape sequences) |
| **Memory Management** | Custom allocator support for embedded use |

## Document Index

| Document | Description |
|----------|-------------|
| [01-CORE-ARCHITECTURE](01-CORE-ARCHITECTURE.md) | Terminal runtime and libghostty integration |
| [02-USER-EXPERIENCE](02-USER-EXPERIENCE.md) | UX flow, # key trigger, command replacement |
| [03-SHELL-INTEGRATION](03-SHELL-INTEGRATION.md) | Shell plugin design for bash/zsh |
| [04-KEY-ENCODING](04-KEY-ENCODING.md) | Key encoding and Kitty keyboard protocol |
| [05-TERMINAL-STATE](05-TERMINAL-STATE.md) | Framebuffer, SGR, OSC, and snapshots |
| [06-SECURITY-POLICY](06-SECURITY-POLICY.md) | Security model and policy engine |
| [07-LLM-INTEGRATION](07-LLM-INTEGRATION.md) | Provider abstraction and CommandPlan schema |
| [08-IMPLEMENTATION-PHASES](08-IMPLEMENTATION-PHASES.md) | Implementation roadmap |

## Technology Stack

- **Language**: Zig 0.15.2+
- **Terminal Library**: libghostty-vt (from Ghostty)
- **HTTP Client**: libcurl
- **Build System**: Zig build with Nix flake support
- **Shells Supported**: bash, zsh (fish planned)

## Goals

### Primary Goals

1. **Accuracy**: Generate correct, executable commands for user requests
2. **Context**: Leverage terminal state for context-aware generation
3. **Speed**: Sub-second response times for simple queries
4. **Safety**: Prevent accidental execution of dangerous commands

### Non-Goals

- Full terminal emulator replacement (use Ghostty for that)
- Interactive command builders with UI
- Shell scripting or automation framework
- IDE integration (focus on terminal-native experience)
