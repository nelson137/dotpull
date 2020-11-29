#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
    echo 'error: must be run as root' >&2
    echo "Try: sudo $0 $*" >&2
    exit 1
fi

PLAYBOOKS=()
PLAYBOOK_CHOICE=
REPO_URL='https://github.com/nelson137/dotpull'

alias pip2='python2 -m pip 2>&1'
alias pip3='python3 -m pip 2>&1'

BOLD="$(tput bold)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
RESET="$(tput sgr0)"

CHECK_MARK="${BOLD}${GREEN}✓${RESET}"

##################################################
#
# SPINNER
#
##################################################

SPINNER='|/-\'
SPINNER_PID=

# Make sure spinner doesn't get left running
trap '_quiet_kill "$SPINNER_PID"' EXIT HUP ABRT

_quiet_kill() {
    kill -9 "$@" &>/dev/null || true
    wait "$@" &>/dev/null || true
}

_start_spinner() {
    [[ "$SPINNER_PID" ]] && return

    while true; do
        for (( i=0; i<${#SPINNER}; i++ )); do
            tput sc
            # Must use '--' because `printf '- '` is an error,
            # it thinks the '-' is part of a flag
            printf -- "${SPINNER:$i:1} "
            sleep .15
            tput rc
        done
    done &

    SPINNER_PID="$!"
}

_stop_spinner() {
    _quiet_kill "$SPINNER_PID"
    SPINNER_PID=
    tput rc
    printf '%2s\n' "$*"
}

##################################################
#
# GITHUB API
#
##################################################

USER='nelson137'
REPO='dotpull'
API_URL="https://api.github.com/repos/$USER/$REPO"

_api_get() {
    RETVAL="$(curl -sSL "${API_URL}${1}")"
    if echo "$RETVAL" | grep -q 'API rate limit exceeded'; then
        curl -sSLI 'https://api.github.com' | awk '
            /^X-Ratelimit-Reset:/{ reset=$2 }
            END {
                print "error: github: rate limit met, will reset at",
                    strftime("%Y-%m-%d %I:%M:%S %P", reset)
            }
        ' >&2
        exit 1
    fi
}

_get_playbooks_from_head() {
    _api_get /commits
    local head_tree_sha="$(echo "$RETVAL" | jq -r '.[0].commit.tree.sha')"

    _api_get "/git/trees/$head_tree_sha"
    echo "$RETVAL" | jq -r '
        def is_yaml: (.|endswith(".yml")) or (.|endswith(".yaml"));
        .tree | map(.path)[] | select(.|is_yaml)
    '
}

##################################################
#
# UTILITIES
#
##################################################

err() {
    [[ "$SPINNER_PID" ]] && _stop_spinner
    echo "error: $*" >&2
    exit 1
}

info() {
    local tag="$1"; shift
    printf "$BOLD[$tag]$RESET $*"
}

info_nl() {
    local tag="$1"; shift
    info "$tag" "$*\n"
}

get_playbooks_list() {
    info github 'Getting list of playbooks from HEAD of master/origin ... '
    _start_spinner
    while read name; do
        PLAYBOOKS+=( "$name" )
    done < <(_get_playbooks_from_head)
    _stop_spinner "$CHECK_MARK"
}

validate_playbook() {
    local choice="$1"; shift
    local playbooks=( "$@" )
    while [ $# -gt 0 ]; do
        [[ "$choice" == "$1" ]] && return
        shift
    done
    err "playbook must be one of: ${playbooks[@]}"
}

select_playbook() {
    local selection books=( "$@" )
    local num=$(( $# - 1 ))

    while true; do
        echo 'Select a host playbook:'
        echo '======================='
        for (( i=0; i<$#; i++ )); do
            echo "  $i) ${books[$i]}"
        done
        printf '\n'

        printf "${BOLD}Choice [0-$num] ${YELLOW}> "
        # Can't use `read -p` because stderr was redirected to /dev/null
        # Redirect in /dev/tty so this script works even when piped into bash
        read -r selection </dev/tty
        printf "$RESET"

        (( selection == -1 )) && exit 0
        (( 0 <= selection && selection < $# )) && break
        printf '\n'
    done

    RETVAL="${books[$selection]}"
}

apt_update() {
    info apt 'Updating package information ... '
    _start_spinner
    if ! apt update -y &>/dev/null; then
        err "apt: unable to update"
    fi
    _stop_spinner "$CHECK_MARK"
}

apt_install() {
    for pkg in "$@"; do
        if dpkg -s "$pkg" &>/dev/null; then
            info_nl apt "Package already installed: $pkg"
        else
            info apt "Installing $pkg ... "
            _start_spinner
            if ! apt install -y "$pkg" &>/dev/null; then
                err "apt: unable to install package: $pkg"
            fi
            _stop_spinner "$CHECK_MARK"
        fi
    done
}

pip3_upgrade() {
    info pip3 'Upgrading pip ... '
    _start_spinner
    if ! pip3 install --upgrade pip &>/dev/null; then
        err "pip3: unable to upgrade pip"
    fi
    _stop_spinner "$CHECK_MARK"
}

pip2_uninstall() {
    for pkg in "$@"; do
        if pip2 show "$pkg" &>/dev/null; then
            info pip2 "Uninstalling $pkg ... "
            _start_spinner
            if ! pip2 uninstall "$pkg" &>/dev/null; then
                err "pip2: unable to uninstall package: $pkg"
            fi
            _stop_spinner "$CHECK_MARK"
        fi
    done
}

pip3_install() {
    for pkg in "$@"; do
        if pip3 show "$pkg" &>/dev/null; then
            info_nl pip3 "Package already installed: $pkg"
        else
            info pip3 "Installing $pkg ... "
            _start_spinner
            if ! pip3 install "$pkg" &>/dev/null; then
                err "pip3: unable to install package: $pkg"
            fi
            _stop_spinner "$CHECK_MARK"
        fi
    done
}

##################################################
#
# MAIN
#
##################################################

usage() {
    echo 'Usage: install.sh PLAYBOOK.yml'
    exit "${1:-0}"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage ;;
            *) [[ "$PLAYBOOK_CHOICE" ]] && usage 1 || PLAYBOOK_CHOICE="$1" ;;
        esac
        shift
    done

    apt_update
    apt_install curl jq

    get_playbooks_list

    # Validate the given playbook or have user choose one
    if [[ "$PLAYBOOK_CHOICE" ]]; then
        validate_playbook "$PLAYBOOK_CHOICE" "${PLAYBOOKS[@]}"
    else
        printf '\n'
        select_playbook "${PLAYBOOKS[@]}"
        PLAYBOOK_CHOICE="$RETVAL"
        printf '\n'
    fi

    apt_install python3 python3-pip

    pip3_upgrade

    # Make sure the python2 docker-py package isn't installed,
    # it conflicts with the python3 package
    pip2_uninstall docker-py

    pip3_install ansible docker

    local title="Executing playbook: $PLAYBOOK_CHOICE"
    printf "\n${GREEN}${BOLD}"
    echo "  ▐▛▀$(printf "▀%.0s" $(seq ${#title}))▀▜▌"
    echo "  ▐▌ ${title} ▐▌"
    echo "  ▐▙▄$(printf "▄%.0s" $(seq ${#title}))▄▟▌"
    printf "${RESET}\n"

    ansible-pull "$PLAYBOOK_CHOICE" -U "$REPO_URL" \
        --purge -c local --ask-become-pass --vault-id=@prompt
}

main "$@"
