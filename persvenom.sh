#!/usr/bin/env bash

# ==========================================================
# PersVenom - tmux Command Wrapper
#
# Executes predefined commands from script_main.conf inside
# an existing tmux session/pane.
#
# Commands are sent silently.
#
# COMMENT: lines are displayed locally.
#
# Errors printed by the target shell are detected and shown
# in RED on the PersVenom terminal.
#
# No completion marker or extra echo command is sent.
#
# Usage:
#   ./main_script.sh -t <tmux-target>
#
# Example:
#   ./main_script.sh -t temp
#   ./main_script.sh -t temp:0
#   ./main_script.sh -t temp:0.1
# ==========================================================

# ==========================================================
# BASH CHECK
# ==========================================================

if [ -z "${BASH_VERSION:-}" ]; then

    echo "Error: This script must be run with Bash."
    echo "Run: bash $0 -t <tmux-target>"

    exit 1

fi


set -uo pipefail


# ==========================================================
# CONFIGURATION
# ==========================================================

TMUX_TARGET=""
CMD_FILE="./script.conf"

# Time to wait before checking the target pane for errors.
# This does NOT send anything to the target.
ERROR_CHECK_DELAY=1

LOG_FILE="./venom.log"
TOOL_TITLE="PersVenom"


# ==========================================================
# USAGE
# ==========================================================

usage() {

    echo "Usage: $0 -t <tmux-target> [-f config-file]"

    echo
    echo "Options:"
    echo "  -t    tmux target (required)"
    echo "  -f    command definition file"
    echo "        (default: ./script_main.conf)"
    echo "  -h    show this help"

    exit 1
}


# ==========================================================
# ARGUMENT PARSING
# ==========================================================

while getopts "t:f:h" opt; do

    case "$opt" in

        t)
            TMUX_TARGET="$OPTARG"
            ;;

        f)
            CMD_FILE="$OPTARG"
            ;;

        h)
            usage
            ;;

        *)
            usage
            ;;

    esac

done


# ==========================================================
# BASIC VALIDATION
# ==========================================================

if [[ -z "$TMUX_TARGET" ]]; then

    echo "Error: -t <tmux-target> is required."

    usage

fi


if [[ ! -f "$CMD_FILE" ]]; then

    echo "Error: command file not found: $CMD_FILE"

    exit 1

fi


if ! command -v tmux >/dev/null 2>&1; then

    echo "Error: tmux is not installed."

    exit 1

fi


# ==========================================================
# LOGGING
# ==========================================================

log() {

    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"

}


# ==========================================================
# COLORS
# ==========================================================

RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
BOLD='\033[1m'
RESET='\033[0m'


# ==========================================================
# BANNER
# ==========================================================

print_banner() {

    local text="$1"

    echo

    if command -v figlet >/dev/null 2>&1; then

        echo -e "${RED}"

        figlet -f standard "$text"

        echo -e "${RESET}"

    else

        local border

        border=$(printf '=%.0s' \
            $(seq 1 $((${#text} + 8))))

        echo -e "${RED}${BOLD}${border}${RESET}"
        echo -e "${RED}${BOLD}==  ${text}  ==${RESET}"
        echo -e "${RED}${BOLD}${border}${RESET}"

    fi

    echo
}


# ==========================================================
# COMMAND CONFIGURATION
# ==========================================================

declare -A OPT_NAME
declare -A OPT_DESC
declare -A OPT_VARS

declare -a CMD_OPT_ID
declare -a CMD_TEXT
declare -a CMD_COMMENT
declare -a SORTED_IDS


# ==========================================================
# LOAD CONFIGURATION
# ==========================================================

current_id=""
pending_comment=""


while IFS= read -r line || [[ -n "$line" ]]; do

    # Handle Windows CRLF configuration files

    line="${line%$'\r'}"


    # ----------------------------------------
    # OPTION
    # ----------------------------------------

    if [[ "$line" =~ ^###[[:space:]]+OPTION[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then

        current_id="${BASH_REMATCH[1]}"

        SORTED_IDS+=("$current_id")

        pending_comment=""

        continue

    fi


    # ----------------------------------------
    # END OPTION
    # ----------------------------------------

    if [[ "$line" =~ ^###[[:space:]]+END[[:space:]]*$ ]]; then

        current_id=""
        pending_comment=""

        continue

    fi


    [[ -z "$current_id" ]] && continue


    # ----------------------------------------
    # NAME
    # ----------------------------------------

    if [[ "$line" == NAME=* ]]; then

        OPT_NAME["$current_id"]="${line#NAME=}"

        continue

    fi


    # ----------------------------------------
    # DESCRIPTION
    # ----------------------------------------

    if [[ "$line" == DESC=* ]]; then

        OPT_DESC["$current_id"]="${line#DESC=}"

        continue

    fi


    # ----------------------------------------
    # VARIABLES
    # ----------------------------------------

    if [[ "$line" == VARS=* ]]; then

        OPT_VARS["$current_id"]="${line#VARS=}"

        continue

    fi


    # ----------------------------------------
    # COMMENT
    # ----------------------------------------

    if [[ "$line" == COMMENT:* ]]; then

        pending_comment="${line#COMMENT:}"

        pending_comment="${pending_comment# }"

        continue

    fi


    # ----------------------------------------
    # COMMAND
    # ----------------------------------------

    if [[ "$line" == CMD:* ]]; then

        CMD_OPT_ID+=("$current_id")

        CMD_TEXT+=("${line#CMD:}")

        CMD_COMMENT+=("$pending_comment")

        pending_comment=""

        continue

    fi

done < "$CMD_FILE"


# ==========================================================
# VALIDATE CONFIGURATION
# ==========================================================

if [[ "${#SORTED_IDS[@]}" -eq 0 ]]; then

    echo "Error: no options found in $CMD_FILE"

    exit 1

fi


# ==========================================================
# PRINT OPTIONS
# ==========================================================

print_option_table() {

    local id

    local id_col=5
    local name_col=25
    local desc_col=55

    local sep

    sep=$(printf -- '-%.0s' \
        $(seq 1 $((id_col + name_col + desc_col + 8))))


    echo -e "${CYAN}${sep}${RESET}"


    printf \
        "${CYAN}%-${id_col}s | %-${name_col}s | %-${desc_col}s${RESET}\n" \
        "#" \
        "NAME" \
        "DESCRIPTION"


    echo -e "${CYAN}${sep}${RESET}"


    for id in "${SORTED_IDS[@]}"; do

        printf \
            "%-${id_col}s | %-${name_col}s | %-${desc_col}s\n" \
            "$id" \
            "${OPT_NAME[$id]:-Unnamed}" \
            "${OPT_DESC[$id]:-No description}"

    done


    echo -e "${CYAN}${sep}${RESET}"

    echo
}


# ==========================================================
# VERIFY TMUX TARGET
# ==========================================================

if ! tmux has-session -t "$TMUX_TARGET" 2>/dev/null; then

    log \
        "ERROR: no tmux session/target matching '$TMUX_TARGET'."

    echo

    echo -e \
        "${RED}Error: tmux target '$TMUX_TARGET' does not exist.${RESET}"

    echo

    echo "Available tmux sessions:"

    tmux ls 2>/dev/null || true

    exit 1

fi


# ==========================================================
# VARIABLE SUBSTITUTION
# ==========================================================

substitute_vars() {

    local cmd="$1"

    shift

    local pair
    local name
    local value


    for pair in "$@"; do

        name="${pair%%=*}"
        value="${pair#*=}"


        # ${VAR}

        cmd="${cmd//\$\{$name\}/$value}"


        # $VAR

        cmd="${cmd//\$$name/$value}"

    done


    printf '%s\n' "$cmd"

}


# ==========================================================
# CLEAN CAPTURED PANE
# ==========================================================

clean_pane_text() {

    sed \
        -E \
        's/\x1B\[[0-9;?]*[ -\/]*[@-~]//g'

}


# ==========================================================
# DETECT COMMAND ERRORS
# ==========================================================

detect_errors() {

    local text="$1"

    local error_lines


    error_lines=$(
        echo "$text" |
        clean_pane_text |
        grep -Ei \
        -e "command not found" \
        -e "not found" \
        -e "not recognized as an internal or external command" \
        -e "is not recognized as an internal or external command" \
        -e "is not recognized as the name of a cmdlet" \
        -e "permission denied" \
        -e "access is denied" \
        -e "access denied" \
        -e "no such file or directory" \
        -e "cannot open" \
        -e "cannot find" \
        -e "file not found" \
        -e "directory not found" \
        -e "invalid argument" \
        -e "invalid option" \
        -e "unknown option" \
        -e "unknown command" \
        -e "syntax error" \
        -e "parse error" \
        -e "failed" \
        -e "fatal:" \
        -e "error:" \
        -e "error " \
        -e "exception" \
        -e "traceback" \
        -e "could not" \
        -e "unable to" \
        -e "denied" \
        -e "cannot" \
        2>/dev/null |
        tail -n 10
    )


    if [[ -n "$error_lines" ]]; then

        echo

        echo -e \
            "${RED}${BOLD}[ERROR DETECTED]${RESET}"

        echo -e \
            "${RED}${error_lines}${RESET}"

        echo

        log \
            "Detected target error for command: $1"

        return 1

    fi


    return 0
}


# ==========================================================
# RUN COMMAND IN TMUX
# ==========================================================

run_remote_command() {

    local cmd="$1"
    local comment="$2"

    local pane_before
    local pane_after


    # ----------------------------------------
    # Display COMMENT only
    # ----------------------------------------

    if [[ -n "$comment" ]]; then

        echo -e "${CYAN}${comment}${RESET}"

    fi


    # ----------------------------------------
    # Capture pane BEFORE command
    #
    # This is only for local comparison.
    # Nothing is sent to tmux.
    # ----------------------------------------

    pane_before=$(
        tmux capture-pane \
            -p \
            -t "$TMUX_TARGET" \
            -S -2000 \
            2>/dev/null
    )


    # ----------------------------------------
    # Send command
    #
    # Absolutely nothing else is sent.
    # ----------------------------------------

    if ! tmux send-keys \
        -t "$TMUX_TARGET" \
        "$cmd" Enter; then

        echo -e \
            "${RED}[ERROR] Failed to send command to tmux.${RESET}"

        log \
            "Failed to send command to '$TMUX_TARGET': $cmd"

        return 1

    fi


    # ----------------------------------------
    # Give the target shell a short amount of
    # time to print an immediate error.
    # ----------------------------------------

    sleep "$ERROR_CHECK_DELAY"


    # ----------------------------------------
    # Capture pane AFTER command
    # ----------------------------------------

    pane_after=$(
        tmux capture-pane \
            -p \
            -t "$TMUX_TARGET" \
            -S -2000 \
            2>/dev/null
    )


    # ----------------------------------------
    # Compare the pane
    #
    # Only inspect text that appeared after
    # the command was sent.
    # ----------------------------------------

    if [[ "$pane_before" != "$pane_after" ]]; then

        detect_errors "$pane_after" "$cmd"

        if [[ "$?" -ne 0 ]]; then

            return 1

        fi

    fi


    return 0
}


# ==========================================================
# RUN SELECTED OPTION
# ==========================================================

run_option() {

    local id="$1"


    # ----------------------------------------
    # Option information
    # ----------------------------------------

    echo

    echo -e \
        "${YELLOW}${BOLD}${OPT_NAME[$id]}${RESET}"

    echo -e \
        "${CYAN}${OPT_DESC[$id]:-No description}${RESET}"

    echo


    # ----------------------------------------
    # Variables
    # ----------------------------------------

    local var_values=()


    if [[ -n "${OPT_VARS[$id]:-}" ]]; then

        echo -e \
            "${YELLOW}This option requires the following values:${RESET}"

        echo


        IFS='|' read -ra var_defs <<< "${OPT_VARS[$id]}"


        for def in "${var_defs[@]}"; do

            local vname
            local vprompt
            local vdefault
            local input


            IFS=':' read -r \
                vname \
                vprompt \
                vdefault <<< "$def"


            if [[ -n "$vdefault" ]]; then

                read -r -e \
                    -p "  $vprompt [$vdefault]: " \
                    input


                if [[ -z "$input" ]]; then

                    input="$vdefault"

                fi

            else

                read -r -e \
                    -p "  $vprompt: " \
                    input

            fi


            var_values+=("${vname}=${input}")

        done


        echo

    fi


    # ----------------------------------------
    # Execute commands
    # ----------------------------------------

    local i
    local resolved
    local failed=0


    for i in "${!CMD_OPT_ID[@]}"; do

        if [[ "${CMD_OPT_ID[$i]}" == "$id" ]]; then


            resolved=$(
                substitute_vars \
                    "${CMD_TEXT[$i]}" \
                    "${var_values[@]}"
            )


            if ! run_remote_command \
                "$resolved" \
                "${CMD_COMMENT[$i]}"; then

                failed=1

            fi

        fi

    done


    # ----------------------------------------
    # Result
    # ----------------------------------------

    if [[ "$failed" -eq 0 ]]; then

        echo
        echo -e \
            "${GREEN}[+] ${OPT_NAME[$id]} completed successfully.${RESET}"
        echo

    else

        echo
        echo -e \
            "${RED}[!] ${OPT_NAME[$id]} completed with errors.${RESET}"
        echo

    fi

}


# ==========================================================
# MAIN PROGRAM
# ==========================================================

print_banner "$TOOL_TITLE"


log \
    "Attached to existing tmux target: $TMUX_TARGET"


echo -e \
    "${CYAN}Target:${RESET} $TMUX_TARGET"

echo


print_option_table


# ==========================================================
# MAIN MENU LOOP
# ==========================================================

while true; do

    read -r -e \
        -p "Enter option # (or 'show options' / 'exit'): " \
        choice


    [[ -z "$choice" ]] && continue


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

        if [[ "$id" == "$choice" ]]; then

            found=1

            run_option "$id"

            break

        fi

    done


    if [[ "$found" -eq 0 ]]; then

        echo -e \
            "${RED}Invalid option: $choice${RESET}"

        echo

    fi

done


# ==========================================================
# EXIT
# ==========================================================

log \
    "Wrapper session ended. Existing tmux session left running."


echo
echo -e "${GREEN}PersVenom exited.${RESET}"
echo


exit 0

