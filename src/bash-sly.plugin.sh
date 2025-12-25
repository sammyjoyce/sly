# bash integration for the Zig binary
# Reliable keybinding: C-x a  (avoid fragile Enter override in Readline)
# Optional: Enter auto-expand for lines starting with "# " when SLY_BASH_ENTER=1
# Type:   # your request
# Then:   press Ctrl-x a   -> buffer is replaced with the command
# Uses CommandPlan JSON schema for enhanced safety and metadata.

__bash_ai_expand() {
  # Only transform if line starts with "# "
  if [[ ${READLINE_LINE} == "# "* ]]; then
    # Ensure the 'sly' binary is available
    if ! command -v sly >/dev/null 2>&1; then
      printf '\e[31m%s\e[0m\n' "sly: command not found (is it on PATH?)"
      return 0
    fi
    local q="${READLINE_LINE:2}"
    local plan_json
    plan_json="$(sly "$q" 2>/dev/null)"
    if [[ -n "$plan_json" && "$plan_json" != Error:* && "$plan_json" != API\ Error:* ]]; then
      # Parse CommandPlan JSON to extract command and args
      # Use jq if available, otherwise fall back to basic parsing
      if command -v jq &>/dev/null; then
        local cmd_base args_array full_cmd
        cmd_base="$(echo "$plan_json" | jq -r '.command')"
        args_array="$(echo "$plan_json" | jq -r '.args[]? // empty')"
        
        # Build full command with args
        full_cmd="$cmd_base"
        if [[ -n "$args_array" ]]; then
          # Properly quote arguments that contain spaces or special characters
          while IFS= read -r arg; do
            # Check if arg needs quoting
            if [[ "$arg" =~ [[:space:]\$\"\'\`\!] ]]; then
              full_cmd="$full_cmd \"${arg//\"/\\\"}\""
            else
              full_cmd="$full_cmd $arg"
            fi
          done <<< "$args_array"
        fi
        
        # Extract metadata for display (optional: show warnings/confirmations)
        local confirm_mode paste_policy
        confirm_mode="$(echo "$plan_json" | jq -r '.confirm_mode')"
        paste_policy="$(echo "$plan_json" | jq -r '.paste_policy')"
        
        # Show warning for dangerous commands
        if [[ "$confirm_mode" == "preview" || "$paste_policy" == "needs_confirm" ]]; then
          printf '\e[33m%s\e[0m\n' "⚠ This command requires confirmation"
        fi
        
        READLINE_LINE="$full_cmd"
        READLINE_POINT=${#READLINE_LINE}
      else
        # Fallback: basic JSON parsing without jq
        # Extract command field: "command":"value"
        local cmd_base="${plan_json#*\"command\":\"}"
        cmd_base="${cmd_base%%\"*}"
        
        # Extract args array (basic approach)
        local args_part="${plan_json#*\"args\":\[}"
        args_part="${args_part%%\]*}"
        
        # Build command with args
        READLINE_LINE="$cmd_base"
        if [[ -n "$args_part" && "$args_part" != "null" ]]; then
          # Remove quotes and commas, split on remaining delimiters
          args_part="${args_part//\"/}"
          args_part="${args_part//,/ }"
          READLINE_LINE="$cmd_base $args_part"
        fi
        
        READLINE_POINT=${#READLINE_LINE}
      fi
    else
      printf '\e[31m%s\e[0m\n' "Failed to generate command"
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
