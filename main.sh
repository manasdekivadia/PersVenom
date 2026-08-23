#!/usr/bin/env bash
#
# run_remote_defense.sh
#
# Menu-driven wrapper that drives an SSH session which is ALREADY LOGGED
# IN and running inside a tmux pane in another terminal. It injects
# keystrokes into that pane and reads back the output — it never opens
# its own SSH connection.
#
# It shows:
#   1. A big red "TITLE" banner
#   2. A table of available options (numbered from 0), read from a
#      command-definitions file
#   3. A prompt to pick an option, msfconsole-style
#   4. After picking, a banner for that option's NAME, then prompts for
#      any on-the-spot variables it needs, then runs its command list
#      against the existing SSH session
#
# REQUIREMENT
#   The pre-existing SSH session must be running inside a tmux pane.
#   Start it like:
#     tmux new -s remote1
#     ssh admin@10.0.0.5
#
# USAGE
#   ./run_remote_defense.sh -t <tmux-target> [-f commands.conf] [-w seconds]
#
#   -t   tmux target (session, session:window, or session:window.pane)
#   -f   path to the command-definitions file (default: ./commands.conf)
#   -w   seconds to wait for each command to finish (default: 15)
#
# COMMAND FILE FORMAT
#   See the bundled commands.conf for a full example. Summary:
#     ### OPTION <id>
#     NAME=<shown in table + as the banner after selecting>
#     DESC=<shown in table>
#     VARS=<VAR:prompt:default>|<VAR2:prompt:default>      (optional)
#     CMD:<command, may reference $VAR or ${VAR}>
#     CMD:<more commands...>
#     ### END

set -uo pipefail

TMUX_TARGET=""
CMDS_FILE="./commands.conf"
WAIT_SECS=15
LOG_FILE="./venom.log"
TOOL_TITLE="PersVenom"

# ---------- arg parsing ----------


usage() {
  echo "Usage: $0 -t <tmux-target> [-f commands.conf] [-w seconds]" >&2
  exit 1
}
 
WAIT_SECS="${WAIT_SECS:-10}"
LOG_FILE="${LOG_FILE:-/tmp/tmux_wrapper.log}"
TOOL_TITLE="${TOOL_TITLE:-TMUX WRAPPER}"
 
while getopts "t:f:w:h" opt; do
  case "$opt" in
    t) TMUX_TARGET="$OPTARG" ;;
    f) CMDS_FILE="$OPTARG" ;;
    w) WAIT_SECS="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
 
[ -z "$TMUX_TARGET" ] && { echo "Error: -t <tmux-target> is required" >&2; usage; }
[ -f "$CMDS_FILE" ] || { echo "Error: commands file not found: $CMDS_FILE" >&2; exit 1; }
 
command -v tmux >/dev/null 2>&1 || { echo "Error: tmux is not installed" >&2; exit 1; }
 
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}
 
# ---------- display helpers ----------
 
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
MAGENTA='\033[1;35m'
BOLD='\033[1m'
RESET='\033[0m'
 
# Big, red, presentable banner. Uses figlet if available, falls back to
# a bordered block if not, so this still works on a bare box.
print_banner() {
  local text="$1"
  echo
  if command -v figlet >/dev/null 2>&1; then
    echo -e "${RED}"
    figlet -f standard "$text"
    echo -e "${RESET}"
  else
    local border
    border=$(printf '=%.0s' $(seq 1 $((${#text} + 8))))
    echo -e "${RED}${BOLD}${border}${RESET}"
    echo -e "${RED}${BOLD}==  ${text}  ==${RESET}"
    echo -e "${RED}${BOLD}${border}${RESET}"
  fi
  echo
}
 
# 3-column table: # | NAME | DESCRIPTION, rows numbered from 0
print_option_table() {
  local id_col=4 name_col=20 desc_col=48
  local sep
  sep=$(printf -- '-%.0s' $(seq 1 $((id_col + name_col + desc_col + 8))))
 
  echo -e "${CYAN}${sep}${RESET}"
  printf "${CYAN}%-${id_col}s | %-${name_col}s | %-${desc_col}s${RESET}\n" "#" "NAME" "DESCRIPTION"
  echo -e "${CYAN}${sep}${RESET}"
  for id in "${SORTED_IDS[@]}"; do
    printf "%-${id_col}s | %-${name_col}s | %-${desc_col}s\n" \
      "$id" "${OPT_NAME[$id]}" "${OPT_DESC[$id]}"
  done
  echo -e "${CYAN}${sep}${RESET}"
  echo
}
 
# ---------- load the command-definitions file ----------
 
declare -A OPT_NAME
declare -A OPT_DESC
declare -A OPT_VARS
declare -a CMD_OPT_ID   # parallel arrays: CMD_OPT_ID[i] -> which option
declare -a CMD_TEXT     # CMD_TEXT[i]   -> the command text
SORTED_IDS=()
 
current_id=""
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^###\ OPTION\ ([0-9]+)[[:space:]]*$ ]]; then
    current_id="${BASH_REMATCH[1]}"
    SORTED_IDS+=("$current_id")
    continue
  fi
  if [[ "$line" =~ ^###\ END[[:space:]]*$ ]]; then
    current_id=""
    continue
  fi
  case "$line" in
    NAME=*)
      [ -n "$current_id" ] && OPT_NAME[$current_id]="${line#NAME=}"
      ;;
    DESC=*)
      [ -n "$current_id" ] && OPT_DESC[$current_id]="${line#DESC=}"
      ;;
    VARS=*)
      [ -n "$current_id" ] && OPT_VARS[$current_id]="${line#VARS=}"
      ;;
    CMD:*)
      [ -n "$current_id" ] && { CMD_OPT_ID+=("$current_id"); CMD_TEXT+=("${line#CMD:}"); }
      ;;
    *)
      : # ignore comments/blank lines
      ;;
  esac
done < "$CMDS_FILE"
 
if [ "${#SORTED_IDS[@]}" -eq 0 ]; then
  echo "Error: no options found in $CMDS" >&2
  exit 1
fi
 
# ---------- verify the existing tmux/SSH session ----------
 
if ! tmux has-session -t "$TMUX_TARGET" 2>/dev/null; then

  log "ERROR: no tmux session/pane matching '$TMUX_TARGET'. List with: tmux ls"
  exit 1
fi
 
trim_trailing_blanks() {
  awk '{buf[NR]=$0} END{last=NR; while (last>0 && buf[last] ~ /^[[:space:]]*$/) last--; for (i=1;i<=last;i++) print buf[i]}'
}
 
# Send one command into the tmux pane and print/log what comes back.
run_remote_command() {
  local cmd="$1"
  local marker="__WRAP_DONE_${RANDOM}_${SECONDS}__"
  local before_lines
  before_lines=$(tmux capture-pane -p -t "$TMUX_TARGET" -S -2000 2>/dev/null | trim_trailing_blanks | wc -l)
 
  # ---- distinct "sending" block ----
  echo
  echo -e "${MAGENTA}${BOLD}>>>>>> SENDING >>>>>>${RESET}"
  echo -e "${MAGENTA}${cmd}${RESET}"
  echo -e "${MAGENTA}${BOLD}>>>>>>>>>>>>>>>>>>>>>>${RESET}"
 
  tmux send-keys -t "$TMUX_TARGET" "$cmd" Enter
  tmux send-keys -t "$TMUX_TARGET" "echo ${marker}\$?" Enter
 
  local found=0 pane_now full
  for ((i = 0; i < WAIT_SECS * 5; i++)); do
    sleep 0.2
    pane_now=$(tmux capture-pane -p -t "$TMUX_TARGET" -S -2000 2>/dev/null)
    if echo "$pane_now" | grep -q "$marker"; then
      found=1
      break
    fi
  done
 
  full=$(tmux capture-pane -p -t "$TMUX_TARGET" -S -2000 2>/dev/null | trim_trailing_blanks)
 
  # ---- distinct "output" block ----
  echo -e "${GREEN}${BOLD}<<<<<< OUTPUT <<<<<<${RESET}"
  echo "$full" | tail -n +"$((before_lines + 1))" | sed "/${marker}/d"
  echo -e "${GREEN}${BOLD}<<<<<<<<<<<<<<<<<<<<<${RESET}"
 
  if [ "$found" -eq 0 ]; then
    log "WARNING: timed out after ${WAIT_SECS}s waiting for command to finish"
  fi
  echo
}
 
# Substitute declared variables ($VAR and ${VAR} forms) into a command
# string using plain string replacement — no eval, so nothing else in
# the command can accidentally get expanded early.
substitute_vars() {
  local cmd="$1"
  shift
  local pair name value
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    cmd="${cmd//\$\{$name\}/$value}"
    cmd="${cmd//\$$name/$value}"
  done
  echo "$cmd"
}
 
# ---------- run a chosen option ----------
 
run_option() {
  local id="$1"
  print_banner "${OPT_NAME[$id]}"
 
  local var_values=()
  if [ -n "${OPT_VARS[$id]:-}" ]; then
    echo -e "${YELLOW}This option needs some values first:${RESET}"
    IFS='|' read -ra var_defs <<< "${OPT_VARS[$id]}"
    for def in "${var_defs[@]}"; do
      IFS=':' read -r vname vprompt vdefault <<< "$def"
      local input
      if [ -n "$vdefault" ]; then
        read -r -e -p "  $vprompt [$vdefault]: " input
        [ -z "$input" ] && input="$vdefault"
      else
        read -r -e -p "  $vprompt: " input
      fi
      var_values+=("${vname}=${input}")
    done
    echo
  fi
 
  echo -e "${YELLOW}Running ${OPT_NAME[$id]}...${RESET}"
  local i
  for i in "${!CMD_OPT_ID[@]}"; do
    if [ "${CMD_OPT_ID[$i]}" = "$id" ]; then
      local resolved
      resolved=$(substitute_vars "${CMD_TEXT[$i]}" "${var_values[@]}")
      run_remote_command "$resolved"
    fi
  done
  echo -e "${YELLOW}Done with ${OPT_NAME[$id]}.${RESET}"
  echo
}
 
# ---------- main input loop ----------
 
print_banner "$TOOL_TITLE"
log "Attached (read/inject mode) to existing session: $TMUX_TARGET"
echo
print_option_table
 
while true; do
  read -r -e -p "Enter option # (or 'show options' / 'exit'): " choice
  [ -z "$choice" ] && continue
 
  case "$choice" in
    exit|quit)
      break
      ;;
    "show options"|options|menu|list)
      print_option_table
      continue
      ;;
  esac
 
  found=0
  for id in "${SORTED_IDS[@]}"; do
    if [ "$id" = "$choice" ]; then
      found=1
      run_option "$id"
      break
    fi
  done
  [ "$found" -eq 0 ] && echo -e "${RED}Invalid option: $choice${RESET}\n"
done
 
log "Wrapper session ended (existing SSH/tmux session left running)."
exit 0
