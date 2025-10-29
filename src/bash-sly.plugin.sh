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
    local cmd
    cmd="$(sly "$q" 2>/dev/null)"
    if [[ -n "$cmd" && "$cmd" != Error:* && "$cmd" != API\ Error:* ]]; then
      READLINE_LINE="$cmd"
      READLINE_POINT=${#READLINE_LINE}
    else
      printf '\e[31m%s\e[0m\n' "Failed to generate command"
      [[ -n "$cmd" ]] && printf '\e[31m%s\e[0m\n' "$cmd"
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
