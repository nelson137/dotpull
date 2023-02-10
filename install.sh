#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
    echo 'error: must be run as root' >&2
    echo "Try: sudo $0 $*" >&2
    exit 1
fi

# Ansible is installed in /usr/local/bin so make sure that it is discoverable
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

PLAYBOOKS=()
PLAYBOOK_CHOICE=
REPO='nelson137/dotpull'
REPO_URL="https://github.com/$REPO"
INVENTORY_URL="https://raw.githubusercontent.com/$REPO/master/inventory.ini"
TEMP_INVENTORY_FILE='/tmp/inventory.ini'

BOLD="$(tput bold)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
RESET="$(tput sgr0)"

CHECK_MARK="${BOLD}${GREEN}✓${RESET}"

##################################################
# TRAPS
##################################################

# region traps

declare -A _TRAP_HANDLERS

_handle_trap() {
    for handler in "${!_TRAP_HANDLERS[@]}"; do "$handler"; done
    exit 1
}

trap _handle_trap HUP INT QUIT ABRT KILL PIPE TERM

_trap_set() { _TRAP_HANDLERS["$1"]=''; }
_trap_del() { unset _TRAP_HANDLERS["$1"]; }

# endregion

##################################################
# LOGGING
##################################################

# region logging

err() {
    [ -n "$SPINNER_PID" ] && stop_spinner
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

# endregion

##################################################
# SPINNER
##################################################

# region spinner

SPINNER='|/-\'
SPINNER_PID=

_quiet_kill() {
    [ $# -eq 0 ] && return
    kill -9 "$@" &>/dev/null || true
    wait "$@" &>/dev/null || true
}

_cleanup_spinner() {
    _quiet_kill "$SPINNER_PID"
    tput rc
}

_trap_cleanup_spinner() { _cleanup_spinner; echo; }

start_spinner() {
    [ -n "$SPINNER_PID" ] && return

    local i
    while true; do
        for (( i=0; i<${#SPINNER}; i++ )); do
            tput sc
            # Must use '--' because `printf '- '` is an error,
            # it thinks the '-' is part of a flag
            printf -- "${*}${SPINNER:$i:1} "
            sleep .15
            tput rc
        done
    done &

    SPINNER_PID="$!"
    _trap_set _trap_cleanup_spinner
}

stop_spinner() {
    _trap_del _trap_cleanup_spinner
    _cleanup_spinner
    SPINNER_PID=
    printf '\e[0K%s\n' "$*"
}

# endregion

##################################################
# UTILITIES
##################################################

# region utils

_python() {
    python -c 'from __future__ import print_function;'"$*"
}

# endregion utils

##################################################
# GITHUB API
##################################################

# region github api

USER='nelson137'
REPO='dotpull'
API_URL="https://api.github.com/repos/$USER/$REPO"

_GH_API_HEADER=

_cleanup_gh_api_header() { rm -f "$_GH_API_HEADER"; }

github_api() {
    local response
    _GH_API_HEADER="$(mktemp /tmp/dotpull-github-api-header-XXXXXX.json)"
    _trap_set _cleanup_gh_api_header
    response="$(curl -sSLD "$_GH_API_HEADER" "${API_URL}${1}")"
    if echo "$response" | grep -q 'API rate limit exceeded'; then
        awk -v IGNORECASE=1 '
            /^X-Ratelimit-Reset:/{
                print "error: github: rate limit met, will reset at",
                    strftime("%Y-%m-%d %I:%M:%S %P", $2)
                exit 1
            }
        ' "$_GH_API_HEADER" >&2
        exit 1
    fi
    _cleanup_gh_api_header
    _GH_API_HEADER=
    _trap_del _cleanup_gh_api_header
    echo "$response"
}

_get_playbooks_from_head() {
    local head_sha
    head_sha="$(github_api /commits | _python 'import json,sys; print(json.loads(sys.stdin.read())[0]["commit"]["tree"]["sha"])')"

    github_api "/git/trees/$head_sha" | _python '
import json,sys
is_yml = lambda p: p.endswith(".yml") or p.endswith(".yaml")
data = json.loads(sys.stdin.read())
[print(x["path"]) for x in data["tree"] if is_yml(x["path"])]'
}

# endregion

##################################################
# CORE
##################################################

# region core

declare OS_ID_LIKE OS_NAME
get_os_info() {
    if [ -f /etc/os-release ]; then
        {
            read OS_ID_LIKE
            read OS_NAME
        } < <(source /etc/os-release; echo "$ID_LIKE"; echo "$NAME")
    else
        err 'failed to determine OS'
    fi
}

get_playbook_list() {
    info github 'Getting list of playbooks from HEAD of master/origin ... '
    start_spinner
    local name
    while read name; do
        PLAYBOOKS+=( "$name" )
    done < <(_get_playbooks_from_head)
    stop_spinner "$CHECK_MARK"
}

validate_playbook() {
    local choice="$1"; shift
    local playbooks=( "$@" )
    while [ $# -gt 0 ]; do
        [ "$choice" = "$1" ] && return
        shift
    done
    err "playbook must be one of: ${playbooks[@]}"
}

_cleanup_color_prompt() { echo "$RESET"; }

select_playbook() {
    local i selection
    local -a books=( "$@" )

    while true; do
        echo 'Select a host playbook:' >&2
        echo '=======================' >&2
        for (( i=0; i<$#; i++ )); do
            echo "  $i) ${books[$i]}" >&2
        done
        printf '\n' >&2

        _trap_set _cleanup_color_prompt
        read -rp "${BOLD}Choice (q to quit) ${YELLOW}> " selection </dev/tty
        #           Fix stdin, see note at bottom for more info => ~~~~~~~~~
        printf "$RESET" >&2
        _trap_del _cleanup_color_prompt

        [[ $selection == q ]] && return 1
        (( 0 <= selection && selection < $# )) && break

        printf '\n' >&2
    done

    PLAYBOOK_CHOICE="${books[$selection]}"
}

install_packages() {
    case "$OS_ID_LIKE" in
        *rhel*) yum_install "$@" ;;
        *debian*) apt_install "$@" ;;
        *) err "unsupported OS: $os_name"
    esac
}

apt_install() {
    info apt 'Updating package index ... '
    start_spinner
    if ! apt update -y &>/dev/null; then
        err "apt: unable to update"
    fi
    stop_spinner "$CHECK_MARK"

    local pkg
    for pkg in "$@"; do
        info apt "Checking for package $pkg ... "
        start_spinner
        if dpkg -s "$pkg" &>/dev/null; then
            stop_spinner "$CHECK_MARK"
        else
            stop_spinner 'not installed'
            info apt "Installing $pkg ... "
            start_spinner
            if ! apt install -y "$pkg" &>/dev/null; then
                err "apt: unable to install package: $pkg"
            fi
            stop_spinner "$CHECK_MARK"
        fi
    done
}

yum_install() {
    local pkg
    for pkg in "$@"; do
        info yum "Checking for package $pkg ... "
        start_spinner
        if rpm -q "$pkg" &>/dev/null; then
            stop_spinner "$CHECK_MARK"
        else
            stop_spinner 'not installed'
            info yum "Installing $pkg ... "
            start_spinner
            if ! yum install -y "$pkg" &>/dev/null; then
                err "yum: unable to install package: $pkg"
            fi
            stop_spinner "$CHECK_MARK"
        fi
    done
}

_pip2() { python2 -m pip "$@" &>/dev/null; }

pip2_uninstall() {
    local pkg
    for pkg in "$@"; do
        if _pip2 show "$pkg"; then
            info pip2 "Uninstalling $pkg ... "
            start_spinner
            if ! _pip2 uninstall "$pkg"; then
                err "pip2: unable to uninstall package: $pkg"
            fi
            stop_spinner "$CHECK_MARK"
        fi
    done
}

_pip3() { python3 -m pip "$@" &>/dev/null; }

pip3_upgrade() {
    info pip3 'Upgrading pip ... '
    start_spinner
    if ! _pip3 install --upgrade pip; then
        err "pip3: unable to upgrade pip"
    fi
    stop_spinner "$CHECK_MARK"
}

pip3_install() {
    local pkg
    for pkg in "$@"; do
        info pip3 "Checking for package $pkg ... "
        start_spinner
        if _pip3 show "$pkg"; then
            stop_spinner "$CHECK_MARK"
        else
            stop_spinner 'not installed'
            info pip3 "Installing $pkg ... "
            start_spinner
            if ! _pip3 install "$pkg"; then
                err "pip3: unable to install package: $pkg"
            fi
            stop_spinner "$CHECK_MARK"
        fi
    done
}

# endregion

##################################################
# MAIN
##################################################

# region main

usage() {
    echo "Usage: $0 PLAYBOOK.yml"
    exit "${1:-0}"
}

_cleanup_inventory_file() { rm -f "$TEMP_INVENTORY_FILE"; }

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage ;;
            *) [ -n "$PLAYBOOK_CHOICE" ] && usage 1 || PLAYBOOK_CHOICE="$1" ;;
        esac
        shift
    done

    get_os_info

    # Install script dependencies
    install_packages curl git

    get_playbook_list

    # Validate the given playbook or have user choose one
    if [ -n "$PLAYBOOK_CHOICE" ]; then
        validate_playbook "$PLAYBOOK_CHOICE" "${PLAYBOOKS[@]}"
    else
        printf '\n'
        select_playbook "${PLAYBOOKS[@]}" || return 0
        printf '\n'
    fi

    # Make sure the python2 docker-py package isn't installed,
    # it conflicts with the python3 package
    pip2_uninstall docker-py

    # Install ansible dependencies
    install_packages gnupg2
    case "$OS_ID_LIKE" in
        *debian*) apt_install python3 python3-pip python3-apt ;;
    esac

    # Install ansible & its python dependencies
    pip3_upgrade
    pip3_install ansible

    local title="Executing playbook: $PLAYBOOK_CHOICE"
    printf "\n${GREEN}${BOLD}"
    echo "  ▐▛▀$(printf "▀%.0s" $(seq ${#title}))▀▜▌"
    echo "  ▐▌ ${title} ▐▌"
    echo "  ▐▙▄$(printf "▄%.0s" $(seq ${#title}))▄▟▌"
    printf "${RESET}\n"

    curl -sSL "$INVENTORY_URL" -o "$TEMP_INVENTORY_FILE"
    _trap_set _cleanup_inventory_file

    ANSIBLE_PYTHON_INTERPRETER="$(which python3)" \
    ANSIBLE_NOCOWS=true \
    ANSIBLE_NOCOLOR=false \
    ANSIBLE_RETRY_FILES_ENABLED=false \
    ANSIBLE_DEPRECATION_WARNINGS=false \
    ansible-pull -U "$REPO_URL" --purge "$PLAYBOOK_CHOICE" \
        --vault-id=@prompt -i "$TEMP_INVENTORY_FILE" -c local \
        </dev/tty
    #   ~~~~~~~~~
    #   ^ Fix stdin for ansible
    #
    # NOTE: This script is intended to be run as `curl ... | sudo bash -` which
    # causes problems when we want to read from stdin in this script (e.g. with
    # `read`) or in ansible (e.g. with `vars_promp`). This is fixed by
    # redirecting the tty (`/dev/tty`) of this process to stdin of the process
    # that needs it.
}

# endregion

main "$@"
