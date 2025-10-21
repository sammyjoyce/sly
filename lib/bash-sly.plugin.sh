# bash integration for the Zig binary
# Type:   # your request
# Then:   press Enter -> buffer is replaced with the command

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
  else
    # Normal Enter behavior
    return 1
  fi
}

__bash_ai_accept_line() {
  if [[ ${READLINE_LINE} == "# "* ]]; then
    __bash_ai_expand
  fi
  # Accept the line (either original or replaced)
  [[ -n ${READLINE_LINE} ]] && history -s "$READLINE_LINE"
  printf '\n'
  eval "$READLINE_LINE"
  READLINE_LINE=""
  READLINE_POINT=0
}

# Bind Enter to our custom handler
bind -x '"\C-m":"__bash_ai_accept_line"'
bind -x '"\C-j":"__bash_ai_accept_line"'

# Keep Ctrl-x a as alternative trigger (for manual expansion without execution)
bind -x '"\C-xa":"__bash_ai_expand"'
