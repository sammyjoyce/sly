# User Experience Specification

## Overview

This document specifies the user experience for sly, focusing on the core interaction model where users press `#` to enter natural language mode, type their request, and receive executable shell commands.

## Core UX Flow

### The Two-Step Execution Model

```
Step 1: Generate Command
┌─────────────────────────────────────────────────────────────────┐
│ $ # find all python files larger than 1MB                       │
│   ↑                                                             │
│   User types # followed by natural language request             │
└─────────────────────────────────────────────────────────────────┘
                              │
                        [Press Enter]
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ $ find . -name "*.py" -size +1M                                 │
│   ↑                                                             │
│   Buffer replaced with generated command                        │
└─────────────────────────────────────────────────────────────────┘

Step 2: Execute (or Edit) Command
                              │
                    [Press Enter again]
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ ./data/process.py                                               │
│ ./src/analysis.py                                               │
│   ↑                                                             │
│   Command executes, output displayed                            │
└─────────────────────────────────────────────────────────────────┘
```

### Flow States

```
┌────────────────┐
│    IDLE        │  Normal shell prompt, awaiting input
└───────┬────────┘
        │ User types "#"
        ▼
┌────────────────┐
│  NL_MODE       │  Natural language input mode
│  (# prefix)    │  User types request in plain English
└───────┬────────┘
        │ Press Enter
        ▼
┌────────────────┐
│  GENERATING    │  Spinner shows progress
│  (API call)    │  LLM generates command
└───────┬────────┘
        │ Generation complete
        ▼
┌────────────────┐
│  PREVIEW       │  Generated command in buffer
│  (editable)    │  User can review/modify
└───────┬────────┘
        │ Press Enter
        ▼
┌────────────────┐
│  EXECUTING     │  Command runs in shell
└───────┬────────┘
        │ Command completes
        ▼
┌────────────────┐
│    IDLE        │  Back to normal prompt
└────────────────┘
```

## Trigger Mechanism

### Hash (#) Key Detection

The `#` character triggers natural language mode when:

1. It appears at the **start of the line** (column 0)
2. Followed by a **space** and natural language text
3. Line contains **no newlines** (single-line input)

### Valid Triggers

```bash
# list all pdf files              ✓  Valid: starts with "# "
# show disk usage                 ✓  Valid: starts with "# "
#list files                       ✗  Invalid: no space after #
echo "# comment"                  ✗  Invalid: not at start of line
git commit -m "# fix"             ✗  Invalid: not at start of line
```

### Why Hash (#)?

1. **Shell comments**: `#` starts a comment in most shells
2. **Muscle memory**: Developers use `#` for annotations
3. **No conflict**: Comments at line start aren't executed anyway
4. **Discoverability**: Natural to type "# what I want to do"

## Input Capture

### Shell Widget Integration

The shell plugin captures the input buffer when Enter is pressed:

```bash
# zsh widget
_sly_accept_line() {
    if [[ "$BUFFER" == "# "* && "$BUFFER" != *$'\n'* ]]; then
        local query="${BUFFER:2}"  # Extract text after "# "
        _sly_generate "$query"
    else
        zle .accept-line           # Normal Enter behavior
    fi
}

zle -N accept-line _sly_accept_line
```

### Context Capture

Along with the query, sly captures context:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Context Bundle                            │
├─────────────────────────────────────────────────────────────────┤
│ • Query text: "find all python files larger than 1MB"          │
│ • Working directory: /home/user/project                        │
│ • Terminal snapshot: last N lines of output                    │
│ • OSC events: directory changes, shell markers                 │
│ • Git status: branch, modified files (if in repo)              │
│ • Project type: detected from package.json, Cargo.toml, etc.   │
└─────────────────────────────────────────────────────────────────┘
```

## Progress Indication

### Spinner Animation

During LLM generation, a spinner animates in the buffer:

```
$ # find all pdf files ⠋
$ # find all pdf files ⠙
$ # find all pdf files ⠹
$ # find all pdf files ⠸
...
```

### Spinner Frames

```
⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
```

### Animation Rate

- **Frame interval**: 100ms
- **Loop**: Continuous until generation completes

### Implementation

```bash
local dots=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
local frame=0
local saved="$BUFFER"

while kill -0 "$pid" 2>/dev/null; do
    BUFFER="$saved ${dots[$((frame % ${#dots[@]} + 1))]}"
    zle redisplay
    ((frame++))
    sleep 0.1
done
```

## Command Preview

### Buffer Replacement

Upon successful generation, the entire buffer is replaced:

```
Before: # list all docker containers
After:  docker ps -a
```

### Cursor Positioning

The cursor is placed at the end of the generated command:

```
docker ps -a▌
           ↑ cursor position
```

### Editability

The user can modify the command before execution:

- **Arrow keys**: Navigate within command
- **Backspace/Delete**: Remove characters
- **Insert text**: Type additional flags/arguments
- **Ctrl+C**: Cancel and clear buffer
- **Ctrl+A/E**: Jump to start/end

## Error Handling

### Generation Failure

When command generation fails:

```
$ # do something impossible
$ ❌ Failed to generate command plan
```

The error is displayed and the buffer is cleared.

### API Errors

```
$ # list files
$ ❌ Failed to generate command plan
$ API Error: Missing API key
```

### Network Timeout

- **Timeout**: 30 seconds
- **Fallback**: Echo provider for testing

### Invalid Response

If the LLM returns unparseable JSON:

```
$ # list files
$ ❌ Failed to parse command from plan
```

## Command Output Format

### JSON CommandPlan

The LLM returns a structured CommandPlan:

```json
{
  "plan_id": "cmd-1749937123456",
  "command": "find",
  "args": [".", "-name", "*.pdf", "-mtime", "-7"],
  "env": {},
  "stdin": null,
  "paste_policy": "auto",
  "confirm_mode": "auto",
  "expectations": [],
  "failure_signals": [],
  "created_at": 1749937123456
}
```

### Shell Expansion

The shell plugin converts the plan to a command string:

```bash
# Using jq
cmd=$(echo "$plan_json" | jq -r '[.command, (.args // [])[]] | join(" ")')
# Result: find . -name *.pdf -mtime -7

# Fallback without jq
base_cmd=$(echo "$plan_json" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | ...)
```

## Confirmation Modes

### Auto Mode (Default for Safe Commands)

```
$ # echo hello
$ echo hello        ← Command appears in buffer
[Press Enter]       ← Executes immediately
hello
```

### Preview Mode (For Potentially Dangerous Commands)

```
$ # delete all log files
$ rm -rf *.log      ← Command appears with warning
⚠️ This command modifies files. Press Enter to confirm.
[Press Enter]       ← Executes after confirmation
```

### Reject Mode (For Blocked Commands)

```
$ # format my hard drive
$ ❌ Command blocked by security policy
```

## Keyboard Shortcuts

### During Natural Language Input

| Key | Action |
|-----|--------|
| `Enter` | Submit query to LLM |
| `Ctrl+C` | Cancel and clear buffer |
| `Ctrl+U` | Clear line |
| `Backspace` | Delete character |
| Arrow keys | Navigate input |

### During Command Preview

| Key | Action |
|-----|--------|
| `Enter` | Execute command |
| `Ctrl+C` | Cancel command |
| Arrow keys | Edit command |
| Any key | Modify command |

### Alternative Trigger (Bash)

For bash without Enter override:

| Key | Action |
|-----|--------|
| `Ctrl+X A` | Expand `# query` to command |

## Visual Feedback

### Mode Indicators

```
┌─────────────────────────────────────────┐
│ NL Mode:    "# query text ⠋"            │
│ Success:    "command text"              │
│ Error:      "❌ Error message"          │
│ Warning:    "⚠️ Warning message"        │
└─────────────────────────────────────────┘
```

### Color Coding (Optional Enhancement)

| State | Color | Symbol |
|-------|-------|--------|
| Generating | Blue | Spinner |
| Success | Default | None |
| Error | Red | ❌ |
| Warning | Yellow | ⚠️ |

## Accessibility Considerations

### Screen Reader Compatibility

- Status changes announced as text
- Spinner indicated as "generating..."
- Errors read aloud with full message

### Keyboard-Only Operation

- All operations accessible via keyboard
- No mouse required
- Tab navigation not applicable (single-line input)

### High Contrast

- Default terminal colors respected
- No reliance on color alone for status

## Performance Targets

| Metric | Target |
|--------|--------|
| Trigger detection | < 1ms |
| Context capture | < 50ms |
| Spinner start | < 10ms |
| Simple queries (LLM) | < 2s |
| Complex queries (LLM) | < 5s |
| Buffer replacement | < 5ms |

## Edge Cases

### Empty Query

```
$ #              ← Just hash and space
[Enter]
$                ← No action, clear buffer
```

### Very Long Query

```
$ # do something very very very very ... (> 1000 chars)
[truncated for LLM context, processed normally]
```

### Special Characters in Query

```
$ # find files with "quotes" and $variables
[Properly escaped in context, not expanded by shell]
```

### Multi-line Paste

```
$ # line 1
  line 2         ← Not triggered (contains newline)
[Treated as normal input, not NL mode]
```

## Future Enhancements

### Interactive Refinement

```
$ # find pdf files
$ find . -name "*.pdf"
$ # but only in the docs folder
$ find ./docs -name "*.pdf"  ← Refined based on follow-up
```

### Command History Integration

```
$ # run last week's report command
$ ./scripts/generate_report.sh --week 51  ← From history
```

### Multi-Command Pipelines

```
$ # find large files and show their sizes
$ find . -size +100M -exec ls -lh {} \;
```
