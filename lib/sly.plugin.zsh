# zsh integration for sly - AI-powered shell command generator
# Provides the "# <request>" + Enter UX, replaces buffer with the command.
#
# Environment variables:
#   SLY_TIMEOUT  - Generation timeout in seconds (default: 30)
#   SLY_SPINNER  - Enable/disable spinner animation (default: 1)
#   SLY_COLOR    - Enable/disable color output (default: 1)

# Portable timeout function (supports Linux timeout, macOS gtimeout, or fallback)
_sly_run_with_timeout() {
  local timeout_secs="$1"
  shift
  
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_secs" "$@"
  else
    # No timeout available, run directly (warn once)
    if [[ -z "$_SLY_TIMEOUT_WARNED" ]]; then
      print -P "%F{yellow}⚠ sly: timeout command not found, running without timeout%f" >&2
      _SLY_TIMEOUT_WARNED=1
    fi
    "$@"
  fi
}

_sly_exec() {
  local query="$1"
  
  # Ensure sly binary is available
  if ! command -v sly >/dev/null 2>&1; then
    if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
      print -P "%F{red}❌ sly: command not found (is it on PATH?)%f"
    else
      print "sly: command not found (is it on PATH?)"
    fi
    BUFFER=""
    zle reset-prompt
    return 0
  fi
  
  local tmp
  tmp="$(mktemp -t sly.XXXXXX)"
  trap "rm -f '$tmp'" EXIT INT TERM
  
  # Capture recent terminal output for context
  local context=""
  
  # Capture last 10 history entries which may contain relevant context
  if command -v fc >/dev/null 2>&1; then
    context="$(fc -ln -10 2>/dev/null | tail -20 || true)"
  fi
  
  # If we have a populated buffer, add that as additional context
  if [[ -n "$BUFFER" ]]; then
    context="${context}${context:+\n}Current buffer: $BUFFER"
  fi
  
  setopt local_options no_monitor no_notify
  local timeout_val="${SLY_TIMEOUT:-30}"
  
  if [[ -n "$context" ]]; then
    ( _sly_run_with_timeout "$timeout_val" sly plan --query "$query" --context "$context" >"$tmp" 2>/dev/null ) &
  else
    ( _sly_run_with_timeout "$timeout_val" sly plan --query "$query" >"$tmp" 2>/dev/null ) &
  fi
  local pid=$!

  # Spinner animation (can be disabled with SLY_SPINNER=0)
  if [[ "${SLY_SPINNER:-1}" -eq 1 ]]; then
    local spinner_chars='/-\|'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
      printf '\rGenerating... %s' "${spinner_chars:$((i % 4)):1}"
      ((i++))
      sleep 0.1
    done
    printf '\r%s\r' "                " # Clear the spinner line
  fi
  wait "$pid" 2>/dev/null

  local plan_json rc
  plan_json="$(cat "$tmp")"; rc=$?
  rm -f "$tmp"
  trap - EXIT INT TERM

  # Check for timeout (exit code 124)
  if [[ $rc -eq 124 ]]; then
    if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
      print -P "%F{red}❌ Generation timed out after ${timeout_val}s%f"
    else
      print "Generation timed out after ${timeout_val}s"
    fi
    BUFFER=""
    zle reset-prompt
    return 0
  fi

  if [[ $rc -eq 0 && -n "$plan_json" && "$plan_json" != Error:* && "$plan_json" != API\ Error:* ]]; then
    # Validate JSON structure before parsing
    local cmd
    if command -v jq >/dev/null 2>&1; then
      # Validate that .command exists
      if ! echo "$plan_json" | jq -e '.command' >/dev/null 2>&1; then
        if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
          print -P "%F{red}❌ Invalid response: missing command field%f"
        else
          print "Invalid response: missing command field"
        fi
        BUFFER=""
        zle reset-prompt
        return 0
      fi
      # Parse with jq for robust JSON parsing
      cmd="$(echo "$plan_json" | jq -r '[.command, (.args // [])[]] | join(" ")' 2>/dev/null)"
    else
      # Fallback: simple extraction (less robust but no dependencies)
      # Extract "command": "value" and "args": ["a", "b"]
      local base_cmd args_str
      base_cmd="$(echo "$plan_json" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
      
      # Validate command was extracted
      if [[ -z "$base_cmd" ]]; then
        if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
          print -P "%F{red}❌ Invalid response: could not parse command%f"
        else
          print "Invalid response: could not parse command"
        fi
        BUFFER=""
        zle reset-prompt
        return 0
      fi
      
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
      if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
        print -P "%F{red}❌ Failed to parse command from plan%f"
      else
        print "Failed to parse command from plan"
      fi
      BUFFER=""
    fi
  else
    if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
      print -P "%F{red}❌ Failed to generate command plan%f"
      [[ -n "$plan_json" ]] && print -P "%F{red}$plan_json%f"
    else
      print "Failed to generate command plan"
      [[ -n "$plan_json" ]] && print "$plan_json"
    fi
    BUFFER=""
  fi
  zle reset-prompt
}

_sly_accept_line() {
  if [[ "$BUFFER" == "# "* && "$BUFFER" != *$'\n'* ]]; then
    local q="${BUFFER:2}"
    # Empty query - just clear buffer and return
    if [[ -z "${q// /}" ]]; then
      BUFFER=""
      zle reset-prompt
      return 0
    fi
    _sly_exec "$q"
  else
    zle .accept-line
  fi
}

# Bind widget
zle -N accept-line _sly_accept_line
