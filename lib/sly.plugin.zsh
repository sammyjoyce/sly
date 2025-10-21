# zsh integration for the Zig binary
# Provides the "# <request>" + Enter UX, replaces buffer with the command.

_zig_ai_exec() {
  local query="$1"
  local tmp
  tmp="$(mktemp)"
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

  local cmd rc
  cmd="$(cat "$tmp")"; rc=$?
  rm -f "$tmp"

  if [[ $rc -eq 0 && -n "$cmd" && "$cmd" != Error:* && "$cmd" != API\ Error:* ]]; then
    BUFFER="$cmd"
    CURSOR=$#BUFFER
  else
    print -P "%F{red}❌ Failed to generate command%f"
    [[ -n "$cmd" ]] && print -P "%F{red}$cmd%f"
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
