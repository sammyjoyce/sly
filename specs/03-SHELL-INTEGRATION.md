# Shell Integration Specification

## Overview

Shell integration is how sly intercepts the `#` trigger, communicates with the sly backend, and replaces the input buffer with the generated command. This document specifies the shell plugin architecture for bash, zsh, and future shells.

## Architecture

### Plugin Communication Model

```
┌──────────────────────────────────────────────────────────────────┐
│                           Shell                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                     Input Buffer                            │  │
│  │  # list all pdf files                                       │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              │                                    │
│                              ▼                                    │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    Shell Plugin                             │  │
│  │  • Intercept Enter key                                      │  │
│  │  • Detect "# " prefix                                       │  │
│  │  • Capture context (history, buffer)                        │  │
│  │  • Display spinner                                          │  │
│  │  • Replace buffer with result                               │  │
│  └────────────────────────────────────────────────────────────┘  │
└────────────────────────────────┬─────────────────────────────────┘
                                 │ subprocess
                                 ▼
┌──────────────────────────────────────────────────────────────────┐
│                          sly CLI                                  │
│  sly plan --query "list all pdf files" --context "..."           │
│                              │                                    │
│                              ▼                                    │
│                       CommandPlan JSON                            │
└──────────────────────────────────────────────────────────────────┘
```

## Zsh Plugin

### Widget Architecture

Zsh Line Editor (ZLE) widgets provide the interception mechanism:

```zsh
# Define custom accept-line widget
_sly_accept_line() {
    if [[ "$BUFFER" == "# "* && "$BUFFER" != *$'\n'* ]]; then
        local query="${BUFFER:2}"
        _sly_generate "$query"
    else
        zle .accept-line  # Call original accept-line
    fi
}

# Register widget
zle -N accept-line _sly_accept_line
```

### Generation Function

```zsh
_sly_generate() {
    local query="$1"
    local tmp="$(mktemp)"
    
    # Capture context
    local context=""
    if command -v fc >/dev/null 2>&1; then
        context="$(fc -ln -10 2>/dev/null | tail -20 || true)"
    fi
    if [[ -n "$BUFFER" ]]; then
        context="${context}${context:+\n}Current buffer: $BUFFER"
    fi
    
    # Disable job control notifications
    setopt local_options no_monitor no_notify
    
    # Run sly in background
    if [[ -n "$context" ]]; then
        ( sly plan --query "$query" --context "$context" >"$tmp" 2>/dev/null ) &
    else
        ( sly plan --query "$query" >"$tmp" 2>/dev/null ) &
    fi
    local pid=$!
    
    # Animate spinner
    local dots=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local frame=0
    local saved="$BUFFER"
    while kill -0 "$pid" 2>/dev/null; do
        BUFFER="$saved ${dots[$((frame % ${#dots[@]} + 1))]}"
        zle redisplay
        ((frame++))
        sleep 0.1
    done
    
    # Read result
    local plan_json rc
    plan_json="$(cat "$tmp")"; rc=$?
    rm -f "$tmp"
    
    # Parse and apply result
    if [[ $rc -eq 0 && -n "$plan_json" && "$plan_json" != Error:* ]]; then
        local cmd
        if command -v jq >/dev/null 2>&1; then
            cmd="$(echo "$plan_json" | jq -r '[.command, (.args // [])[]] | join(" ")')"
        else
            # Fallback parsing
            local base_cmd args_str
            base_cmd="$(echo "$plan_json" | grep -o '"command":"[^"]*"' | cut -d'"' -f4)"
            args_str="$(echo "$plan_json" | grep -o '"args":\[[^]]*\]' | sed 's/.*\[\(.*\)\].*/\1/' | tr -d '\"' | tr ',' ' ')"
            cmd="$base_cmd $args_str"
        fi
        
        if [[ -n "$cmd" ]]; then
            BUFFER="$cmd"
            CURSOR=$#BUFFER
        else
            print -P "%F{red}❌ Failed to parse command from plan%f"
            BUFFER=""
        fi
    else
        print -P "%F{red}❌ Failed to generate command plan%f"
        [[ -n "$plan_json" ]] && print -P "%F{red}$plan_json%f"
        BUFFER=""
    fi
    
    zle reset-prompt
}
```

### Zsh-Specific Features

| Feature | Implementation |
|---------|----------------|
| Buffer access | `$BUFFER` variable |
| Cursor control | `$CURSOR` variable |
| Redisplay | `zle redisplay` |
| History access | `fc -ln -N` command |
| Job control | `setopt local_options no_monitor no_notify` |
| Color output | `print -P "%F{color}...%f"` |

## Bash Plugin

### Readline Integration

Bash uses Readline for line editing. Integration is more limited than zsh:

```bash
# Function to expand "# query" to command
__sly_expand() {
    if [[ ${READLINE_LINE} == "# "* ]]; then
        if ! command -v sly >/dev/null 2>&1; then
            printf '\e[31m%s\e[0m\n' "sly: command not found"
            return 0
        fi
        
        local query="${READLINE_LINE:2}"
        local plan_json cmd
        
        # Capture context
        local context=""
        if command -v history >/dev/null 2>&1; then
            context="$(history 10 2>/dev/null | tail -20 || true)"
        fi
        if [[ -n "$READLINE_LINE" ]]; then
            context="${context}${context:+$'\n'}Current buffer: $READLINE_LINE"
        fi
        
        # Call sly
        if [[ -n "$context" ]]; then
            plan_json="$(sly plan --query "$query" --context "$context" 2>/dev/null)"
        else
            plan_json="$(sly plan --query "$query" 2>/dev/null)"
        fi
        
        # Parse result
        if [[ -n "$plan_json" && "$plan_json" != Error:* ]]; then
            if command -v jq >/dev/null 2>&1; then
                cmd="$(echo "$plan_json" | jq -r '[.command, (.args // [])[]] | join(" ")')"
            else
                local base_cmd args_str
                base_cmd="$(echo "$plan_json" | grep -o '"command":"[^"]*"' | cut -d'"' -f4)"
                args_str="$(echo "$plan_json" | grep -o '"args":\[[^]]*\]' | sed 's/.*\[\(.*\)\].*/\1/' | tr -d '\"' | tr ',' ' ')"
                cmd="$base_cmd $args_str"
            fi
            
            if [[ -n "$cmd" ]]; then
                READLINE_LINE="$cmd"
                READLINE_POINT=${#READLINE_LINE}
            else
                printf '\e[31m%s\e[0m\n' "Failed to parse command"
                READLINE_LINE=""
                READLINE_POINT=0
            fi
        else
            printf '\e[31m%s\e[0m\n' "Failed to generate command"
            READLINE_LINE=""
            READLINE_POINT=0
        fi
    fi
}
```

### Keybinding Options

#### Option 1: Ctrl+X A (Explicit Trigger)

```bash
# Reliable explicit expansion
bind -x '"\C-xa":"__sly_expand"'
```

#### Option 2: Enter Override (Optional)

```bash
# Enable with SLY_BASH_ENTER=1
if [[ ${SLY_BASH_ENTER:-0} -eq 1 ]]; then
    __sly_maybe_enter() {
        if [[ ${READLINE_LINE} == "# "* ]]; then
            __sly_expand
            return 0
        fi
        # Fallback to normal accept-line
        READLINE_PENDING_INPUT=$'\C-j'
    }
    
    bind '"\C-j": accept-line'
    bind -x '"\C-m":"__sly_maybe_enter"'
fi
```

### Bash Limitations

| Limitation | Workaround |
|------------|------------|
| No async redisplay | Synchronous call (no spinner) |
| Limited buffer control | `READLINE_LINE` and `READLINE_POINT` only |
| Enter binding fragility | Ctrl+X A alternative |
| No color in prompt | ANSI escapes via printf |

## Fish Plugin (Future)

### Fish Function Architecture

```fish
function _sly_fish --on-event fish_preexec
    if string match -qr '^# ' -- $argv
        set -l query (string sub -s 3 -- $argv)
        set -l result (sly plan --query "$query" 2>/dev/null)
        
        if test -n "$result"
            # Parse and execute
            set -l cmd (echo $result | jq -r '[.command, (.args // [])[]] | join(" ")')
            commandline -r $cmd
            commandline -f execute
        end
    end
end
```

### Fish-Specific Considerations

- Native async support via `fish_async_prompt`
- Better Unicode handling
- Built-in JSON parsing (via string manipulation)
- Event-based hooks

## Context Capture

### History Integration

#### Zsh

```zsh
# Last 10 history entries
context="$(fc -ln -10 2>/dev/null | tail -20 || true)"
```

#### Bash

```bash
# Last 10 history entries
context="$(history 10 2>/dev/null | tail -20 || true)"
```

### Terminal State Capture

For full terminal context, the shell plugin can invoke sly with additional flags:

```bash
# Future: capture terminal snapshot
sly plan --query "$query" --terminal-context
```

This triggers the Terminal Runtime to capture:
- Recent terminal output (framebuffer)
- OSC events (directory changes, shell markers)
- Current working directory

## Installation

### Automatic Installation

```bash
# Install and configure automatically
sly shell install --auto
```

This:
1. Creates `~/.config/sly/sly.plugin.{zsh,sh}`
2. Adds source line to `~/.zshrc` or `~/.bashrc`

### Manual Installation

```bash
# 1. Install plugin file
sly shell install

# 2. Add to shell config manually
# For zsh (~/.zshrc):
source ~/.config/sly/sly.plugin.zsh

# For bash (~/.bashrc):
source ~/.config/sly/sly.plugin.sh
```

### Per-Shell Detection

```bash
# Detect shell from $SHELL
case "$(basename "$SHELL")" in
    zsh)  PLUGIN_FILE="sly.plugin.zsh" ;;
    bash) PLUGIN_FILE="sly.plugin.sh" ;;
    *)    echo "Unsupported shell" ;;
esac
```

## Plugin Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SLY_BASH_ENTER` | `0` | Enable Enter override in bash |
| `SLY_TIMEOUT` | `30` | Generation timeout in seconds |
| `SLY_SPINNER` | `1` | Enable/disable spinner |
| `SLY_COLOR` | `1` | Enable/disable color output |

### Runtime Configuration

```bash
# Disable spinner
export SLY_SPINNER=0

# Increase timeout
export SLY_TIMEOUT=60

# Force specific provider
export SLY_PROVIDER=ollama
```

## Error Handling

### sly Not Found

```bash
if ! command -v sly >/dev/null 2>&1; then
    printf '\e[31m%s\e[0m\n' "sly: command not found (is it on PATH?)"
    return 0
fi
```

### Generation Timeout

```bash
# Timeout wrapper
timeout ${SLY_TIMEOUT:-30} sly plan --query "$query" >"$tmp" 2>/dev/null
if [[ $? -eq 124 ]]; then
    printf '\e[31m%s\e[0m\n' "Generation timed out"
fi
```

### Invalid JSON Response

```bash
if ! echo "$plan_json" | jq -e '.command' >/dev/null 2>&1; then
    printf '\e[31m%s\e[0m\n' "Invalid response from sly"
    return 0
fi
```

## JSON Parsing

### With jq (Recommended)

```bash
cmd="$(echo "$plan_json" | jq -r '[.command, (.args // [])[]] | join(" ")')"
```

### Without jq (Fallback)

```bash
# Extract command
base_cmd="$(echo "$plan_json" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | \
           sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"

# Extract args array
args_str="$(echo "$plan_json" | grep -o '"args"[[:space:]]*:[[:space:]]*\[[^]]*\]' | \
           sed 's/.*"args"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/' | \
           sed 's/"//g' | sed 's/,/ /g')"

# Combine
if [[ -n "$args_str" ]]; then
    cmd="$base_cmd $args_str"
else
    cmd="$base_cmd"
fi
```

## Plugin Versioning

### Version Check

```bash
# Check sly version compatibility
SLY_VERSION=$(sly --version 2>/dev/null | head -1)
if [[ -z "$SLY_VERSION" ]]; then
    echo "Warning: Unable to determine sly version"
fi
```

### Upgrade Path

Plugins are embedded in the sly binary and installed via `sly shell install`. Updates to the plugin require:

1. Update sly binary
2. Re-run `sly shell install`
3. Restart shell or re-source plugin

## Testing

### Manual Testing

```bash
# Test pattern matching
[[ "# test query" == "# "* ]] && echo "Match!"

# Test jq parsing
echo '{"command":"echo","args":["hello"]}' | jq -r '[.command, .args[]] | join(" ")'

# Test fallback parsing
echo '{"command":"echo","args":["hello"]}' | grep -o '"command":"[^"]*"'
```

### Integration Testing

```bash
# Test with echo provider (offline)
SLY_PROVIDER=echo sly plan --query "test"

# Verify JSON output
SLY_PROVIDER=echo sly plan --query "test" | jq .
```

## Security Considerations

### Command Injection Prevention

- Shell plugin does not directly execute generated commands
- Buffer replacement requires user to press Enter
- No eval or execution of untrusted strings

### Path Safety

```bash
# Use full path for critical commands
/usr/bin/sly plan --query "$query"
```

### Temporary File Security

```bash
# Secure temp file creation
tmp="$(mktemp -t sly.XXXXXX)"
trap "rm -f $tmp" EXIT
```
