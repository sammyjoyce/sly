# bash integration for the Zig binary
# Reliable keybinding: C-x a  (avoid fragile Enter override in Readline)
# Optional: Enter auto-expand for lines starting with "# " when SLY_BASH_ENTER=1
# Type:   # your request
# Then:   press Ctrl-x a   -> buffer is replaced with the command

__bash_ai_expand() {
  # Only transform if line starts with "# "
  if [[ ${READLINE_LINE} == "# "* ]]; then
    # Ensure the 'sly' binary is available
    if ! command -v sly >/dev/null 2>&1; then
      printf '\e[31m%s\e[0m\n' "sly: command not found (is it on PATH?)"
      return 0
    fi
    local q="${READLINE_LINE:2}"
    local plan_json cmd
    
    # Capture recent terminal output for context
    # In bash, we can capture recent history to provide AI with context
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
    if [[ -n "$context" ]]; then
      plan_json="$(sly plan --query "$q" --context "$context" 2>/dev/null)"
    else
      plan_json="$(sly plan --query "$q" 2>/dev/null)"
    fi
    
    if [[ -n "$plan_json" && "$plan_json" != Error:* && "$plan_json" != API\ Error:* ]]; then
      # Parse JSON to extract command and args
      # Use jq if available, otherwise fall back to simple grep/sed extraction
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
        READLINE_LINE="$cmd"
        READLINE_POINT=${#READLINE_LINE}
      else
        printf '\e[31m%s\e[0m\n' "Failed to parse command from plan"
        READLINE_LINE=""
        READLINE_POINT=0
      fi
    else
      printf '\e[31m%s\e[0m\n' "Failed to generate command plan"
      [[ -n "$plan_json" ]] && printf '\e[31m%s\e[0m\n' "$plan_json"
      READLINE_LINE=""
      READLINE_POINT=0
    fi
  fi
}

# Only proceed in interactive shells
if [[ $- == *i* ]]; then
  # Bind Ctrl-x a (reliable explicit expansion)
  bind -x '"\C-xa":"__bash_ai_expand"'

  # Optional Enter hook: expand "# <query>" on first Enter, execute on second Enter.
  # Disabled by default; enable with: export SLY_BASH_ENTER=1
  __bash_sly_maybe_enter() {
    # If line starts with "# ", expand via sly but DO NOT execute yet
    if [[ ${READLINE_LINE} == "# "* ]]; then
      __bash_ai_expand
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
    bind -x '"\C-m":"__bash_sly_maybe_enter"'
  fi
fi
