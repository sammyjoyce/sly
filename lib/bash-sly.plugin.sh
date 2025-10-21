# bash integration for the Zig binary
# Reliable keybinding: C-x a  (avoid fragile Enter override in Readline)
# Type:   # your request
# Then:   press Ctrl-x a   -> buffer is replaced with the command

__bash_ai_expand() {
  # Only transform if line starts with "# "
  if [[ ${READLINE_LINE} == "# "* ]]; then
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

# Bind Ctrl-x a
bind -x '"\C-xa":"__bash_ai_expand"'
