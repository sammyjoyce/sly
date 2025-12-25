# zsh integration for the Zig binary
# Provides the "# <request>" + Enter UX, replaces buffer with the command.

_zig_ai_exec() {
  local query="$1"
  local tmp
  tmp="$(mktemp)"
  
  # Capture recent terminal output for context
  # We want to capture the visible terminal content to provide AI with context
  local context=""
  
  # Strategy 1: Use 'script' command to capture terminal if available
  # Strategy 2: Capture recent command history with output
  # Strategy 3: At minimum, capture last few commands from history
  
  # Try to get last command and its output from history
  # We'll capture the last 10 history entries which may contain relevant context
  if command -v fc >/dev/null 2>&1; then
    context="$(fc -ln -10 2>/dev/null | tail -20 || true)"
  fi
  
  # If we have a populated buffer, add that as additional context
  if [[ -n "$BUFFER" ]]; then
    context="${context}${context:+\n}Current buffer: $BUFFER"
  fi
  
  setopt local_options no_monitor no_notify
  if [[ -n "$context" ]]; then
    ( sly plan --query "$query" --context "$context" >"$tmp" 2>/dev/null ) &
  else
    ( sly plan --query "$query" >"$tmp" 2>/dev/null ) &
  fi
  local pid=$!

  local dots=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local f=0
  local saved="$BUFFER"
  while kill -0 "$pid" 2>/dev/null; do
    BUFFER="$saved ${dots[$((f % ${#dots[@]} + 1))]}"
    zle redisplay
    ((f++))
    sleep 0.1
  done

  local plan_json rc
  plan_json="$(cat "$tmp")"; rc=$?
  rm -f "$tmp"

  if [[ $rc -eq 0 && -n "$plan_json" && "$plan_json" != Error:* && "$plan_json" != API\ Error:* ]]; then
    # Parse JSON to extract command and args
    # Use jq if available, otherwise fall back to simple grep/sed extraction
    local cmd
    if command -v jq >/dev/null 2>&1; then
      # Parse with jq for robust JSON parsing
      cmd="$(echo "$plan_json" | jq -r '[.command, (.args // [])[]] | join(" ")' 2>/dev/null)"
    else
      # Fallback: simple extraction (less robust but no dependencies)
      # Extract "command": "value" and "args": ["a", "b"]
      local base_cmd args_str
      base_cmd="$(echo "$plan_json" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
      args_str="$(echo "$plan_json" | grep -o '"args"[[:space:]]*:[[:space:]]*\[[^]]*\]' | sed 's/.*"args"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/' | sed 's/"//g' | sed 's/,/ /g')"
      if [[ -n "$args_str" ]]; then
        cmd="$base_cmd $args_str"
      else
        cmd="$base_cmd"
      fi
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

_zig_ai_accept_line() {
  if [[ "$BUFFER" == "# "* && "$BUFFER" != *$'\n'* ]]; then
    local q="${BUFFER:2}"
    _zig_ai_exec "$q"
  else
    zle .accept-line
  fi
}

# Bind widget
zle -N accept-line _zig_ai_accept_line
