#!/usr/bin/env bash

#set -uo pipefail

TMUX_TARGET=""
WAIT_SEC=15 
LOG_FILE="./venom.log"
TOOL_TITLE="PersVenom"
CMD_FILE="script.conf"

usage(){
	echo "Usage : $0 -t <tmux-target> [-w seconds]" >&2
	exit 1 
}

# We check if WAIT_SEC is set or NOT
if [[ -z "$WAIT_SEC" ]];then
       WAIT_SEC=10
fi

# We check if the LOG_FILE is set or NOT
if [[ -z "$LOG_FILE" ]];then
	LOG_FILE=/tmp/tmux_wrapper.log
fi

# Putting the Option Parsing Feature


while getopts "t:w:h" opt;do
	case "$opt" in 
		t) TMUX_TARGET="$OPTARG";;
		w) WAIT_SEC="$OPTARG" ;;
		h)usage;;
		*)usage;;
	esac
done



# Checking if TMUX_TARGET is set or NOT


if [[ -z "$TMUX_TARGET" ]];then 
	echo "Error: -t <tmux-target> is required";
	usage;
fi


command -v tmux>/dev/null  2>&1 || { echo "Error: tmux is not installed" >&2;
exit 1; }

# Writting the log function


log(){
	echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a $LOG_FILE
	
}

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
 
# MAIN READING FUNCTIONS
declare -A DESC
declare -A VAR
declare -A CMD

SORTED_IDS=()
current_id=""

while IFS= read -r line; do
    #echo "READING: [$line]"
    if [[ "$line" =~ ^#OPTION[[:space:]]+([0-9]+)$ ]]; then
	current_id="${BASH_REMATCH[1]}"
        SORTED_IDS+=("$current_id")
        continue
    fi

    [[ -z "$current_id" ]] && continue

    if [[ "$line" =~ ^#DESCRIPTION=(.*)$ ]]; then
        DESC["$current_id"]="${BASH_REMATCH[1]}"
        continue
    fi

    if [[ "$line" =~ ^#VARIABLE=(.*)$ ]]; then
        VAR["$current_id"]="${BASH_REMATCH[1]}"
        continue
    fi

    if [[ "$line" =~ ^#COMMANDS=(.*)$ ]]; then
        CMD["$current_id"]="${BASH_REMATCH[1]}"
        continue
    fi

    if [[ "$line" =~ ^#END[[:space:]]*$ ]]; then
        current_id=""
        continue
    fi

done < "$CMD_FILE"

for id in "${SORTED_IDS[@]}"; do
    echo "===================="
    echo "OPTION: $id"
    echo "DESCRIPTION: ${DESC[$id]}"
    echo "VARIABLE: ${VAR[$id]}"
    echo "COMMAND: ${CMD[$id]}"
done


## VERIFYING TMUX SESSION

if ! tmux has-session -t "$TMUX_TARGET" 2 > /dev/null; then 
	log "Error: No Tmux session matching '$TMUX_TARGET' found. Use tmux -l to list the tmux session available"
	exit 1
fi

trim_trailing_blanks() {
	awk '{buf[NR]=$0 END{last=NR;
}
