# zsh integration for the Zig binary
# Provides the "# <request>" + Enter UX, replaces buffer with the command.
# Uses CommandPlan JSON schema for enhanced safety and metadata.

_zig_ai_exec() {
  local query="$1"
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  setopt local_options no_monitor no_notify
  ( sly "$query" >"$tmp" 2>/dev/null ) &
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
        print -P "%F{yellow}⚠ This command requires confirmation%f"
      fi
      
      BUFFER="$full_cmd"
      CURSOR=$#BUFFER
    else
      # Fallback: basic JSON parsing without jq
      # Extract command field: "command":"value"
      local cmd_base="${plan_json#*\"command\":\"}"
      cmd_base="${cmd_base%%\"*}"
      
      # Extract args array (basic approach)
      local args_part="${plan_json#*\"args\":\[}"
      args_part="${args_part%%\]*}"
      
      # Build command with args
      BUFFER="$cmd_base"
      if [[ -n "$args_part" && "$args_part" != "null" ]]; then
        # Remove quotes and commas, split on remaining delimiters
        args_part="${args_part//\"/}"
        args_part="${args_part//,/ }"
        BUFFER="$cmd_base $args_part"
      fi
      
      CURSOR=$#BUFFER
    fi
  else
    print -P "%F{red}❌ Failed to generate command%f"
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
