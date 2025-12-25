# bash integration for sly - AI-powered shell command generator
# Reliable keybinding: C-x a  (avoid fragile Enter override in Readline)
# Optional: Enter auto-expand for lines starting with "# " when SLY_BASH_ENTER=1
# Type:   # your request
# Then:   press Ctrl-x a   -> buffer is replaced with the command
#
# Environment variables:
#   SLY_TIMEOUT     - Generation timeout in seconds (default: 30)
#   SLY_COLOR       - Enable/disable color output (default: 1)
#   SLY_BASH_ENTER  - Enable Enter key override (default: 0)

# Portable timeout function (supports Linux timeout, macOS gtimeout, or fallback)
__sly_run_with_timeout() {
  local timeout_secs="$1"
  shift
  
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_secs" "$@"
  else
    # No timeout available, run directly (warn once)
    if [[ -z "$_SLY_TIMEOUT_WARNED" ]]; then
      printf '\e[33m%s\e[0m\n' "⚠ sly: timeout command not found, running without timeout" >&2
      _SLY_TIMEOUT_WARNED=1
    fi
    "$@"
  fi
}

__sly_expand() {
  # Only transform if line starts with "# "
  if [[ ${READLINE_LINE} == "# "* ]]; then
    # Ensure the 'sly' binary is available
    if ! command -v sly >/dev/null 2>&1; then
      if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
        printf '\e[31m%s\e[0m\n' "sly: command not found (is it on PATH?)"
      else
        printf '%s\n' "sly: command not found (is it on PATH?)"
      fi
      return 0
    fi
    local q="${READLINE_LINE:2}"
    local plan_json cmd
    local timeout_val="${SLY_TIMEOUT:-30}"
    
    # Capture recent terminal output for context
    local context=""
    
    # Capture last 10 history entries which may contain relevant context
    if command -v history >/dev/null 2>&1; then
      context="$(history 10 2>/dev/null | tail -20 || true)"
    fi
    
    # If we have a populated READLINE_LINE, add that as additional context
    if [[ -n "$READLINE_LINE" ]]; then
      context="${context}${context:+$'\n'}Current buffer: $READLINE_LINE"
    fi
    
    # Call sly plan with context if available
    local rc=0
    if [[ -n "$context" ]]; then
      plan_json="$(__sly_run_with_timeout "$timeout_val" sly plan --query "$q" --context "$context" 2>/dev/null)"; rc=$?
    else
      plan_json="$(__sly_run_with_timeout "$timeout_val" sly plan --query "$q" 2>/dev/null)"; rc=$?
    fi
    
    # Check for timeout (exit code 124)
    if [[ $rc -eq 124 ]]; then
      if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
        printf '\e[31m%s\e[0m\n' "Generation timed out after ${timeout_val}s"
      else
        printf '%s\n' "Generation timed out after ${timeout_val}s"
      fi
      READLINE_LINE=""
      READLINE_POINT=0
      return 0
    fi
    
    if [[ -n "$plan_json" && "$plan_json" != Error:* && "$plan_json" != API\ Error:* ]]; then
      # Parse JSON to extract command and args
      # Use jq if available, otherwise fall back to simple grep/sed extraction
      if command -v jq >/dev/null 2>&1; then
        # Validate that .command exists
        if ! echo "$plan_json" | jq -e '.command' >/dev/null 2>&1; then
          if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
            printf '\e[31m%s\e[0m\n' "Invalid response: missing command field"
          else
            printf '%s\n' "Invalid response: missing command field"
          fi
          READLINE_LINE=""
          READLINE_POINT=0
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
            printf '\e[31m%s\e[0m\n' "Invalid response: could not parse command"
          else
            printf '%s\n' "Invalid response: could not parse command"
          fi
          READLINE_LINE=""
          READLINE_POINT=0
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
        READLINE_LINE="$cmd"
        READLINE_POINT=${#READLINE_LINE}
      else
        if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
          printf '\e[31m%s\e[0m\n' "Failed to parse command from plan"
        else
          printf '%s\n' "Failed to parse command from plan"
        fi
        READLINE_LINE=""
        READLINE_POINT=0
      fi
    else
      if [[ "${SLY_COLOR:-1}" -eq 1 ]]; then
        printf '\e[31m%s\e[0m\n' "Failed to generate command plan"
        [[ -n "$plan_json" ]] && printf '\e[31m%s\e[0m\n' "$plan_json"
      else
        printf '%s\n' "Failed to generate command plan"
        [[ -n "$plan_json" ]] && printf '%s\n' "$plan_json"
      fi
      READLINE_LINE=""
      READLINE_POINT=0
    fi
  fi
}

# Only proceed in interactive shells
if [[ $- == *i* ]]; then
  # Bind Ctrl-x a (reliable explicit expansion)
  bind -x '"\C-xa":"__sly_expand"'

  # Optional Enter hook: expand "# <query>" on first Enter, execute on second Enter.
  # Disabled by default; enable with: export SLY_BASH_ENTER=1
  __sly_maybe_enter() {
    # If line starts with "# ", expand via sly but DO NOT execute yet
    if [[ ${READLINE_LINE} == "# "* ]]; then
      __sly_expand
      # Leave the expanded command in the buffer; user presses Enter again to run
      return 0
    fi
    # Fallback to default accept-line by stuffing Ctrl-J into the pending input.
    READLINE_PENDING_INPUT=$'\C-j'
  }

  # Conditionally bind Enter to the maybe-expand handler
  if [[ ${SLY_BASH_ENTER:-0} -eq 1 ]]; then
    # Ensure Ctrl-J is mapped to accept-line for the fallback path
    bind '"\C-j": accept-line'
    bind -x '"\C-m":"__sly_maybe_enter"'
  fi
fi
