#!/bin/bash

set -eo pipefail

# Cache sudo password
sudo -l mkdir &>/dev/null

DID_FETCH_PLAYBOOKS=
PLAYBOOKS=()
PLAYBOOK_CHOICE=
REPO='nelson137/dotpull'
REPO_URL="https://github.com/$REPO"

BOLD="$(tput bold)"
RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
RESET="$(tput sgr0)"

CHECK_MARK="${BOLD}${GREEN}✓${RESET}"
X_MARK="${BOLD}${RED}✘${RESET}"

##################################################
# TRAPS
##################################################

# region traps

declare -a _TRAP_HANDLERS

_handle_trap() {
    for handler in "${_TRAP_HANDLERS[@]}"; do "$handler"; done
    exit 1
}

trap _handle_trap HUP INT QUIT ABRT KILL PIPE TERM

_trap_enter() { _TRAP_HANDLERS+=( "$1" ); }

_trap_del() {
    local handler="$1"
    local -a new_handlers
    set -- "${_TRAP_HANDLERS[@]}"
    while (( $# > 0 )); do
        [ "$1" = "$handler" ] || new_handlers+=( "$1" )
        shift
    done
    _TRAP_HANDLERS=( "${new_handlers[@]}" )
}

_trap_exit() {
    eval "$@"
    _trap_del "$1"
}

# endregion

##################################################
# LOGGING
##################################################

# region logging

err() {
    [ -n "$SPINNER_PID" ] && stop_spinner " $X_MARK"
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

_trap_cleanup_spinner() { _quiet_kill "$SPINNER_PID"; echo; }

start_spinner() {
    [ -n "$SPINNER_PID" ] && return

    info "$@"
    tput sc

    local i
    while true; do
        for (( i=0; i<${#SPINNER}; i++ )); do
            # Must use '--' because `printf '- '` is an error,
            # it thinks the '-' is part of a flag
            printf -- "... ${SPINNER:$i:1} "
            sleep .15
            tput rc
        done
    done &

    SPINNER_PID="$!"
    _trap_enter _trap_cleanup_spinner
}

stop_spinner() {
    local status="${1:- $CHECK_MARK}"
    _trap_del _trap_cleanup_spinner
    _quiet_kill "$SPINNER_PID"
    SPINNER_PID=
    tput rc
    printf '\e[0K%s\n' "$status"
}

# endregion

##################################################
# UTILITIES
##################################################

# region utils

_python() {
    python3 -c "$*"
}

in_git_repo() {
    git rev-parse --is-inside-work-tree &>/dev/null
}

in_self() {
    in_git_repo && git ls-remote --get-url | grep -q "$REPO"
}

# endregion utils

##################################################
# GITHUB API
##################################################

# region github api

_API_URL="https://api.github.com/repos/$REPO"

_GH_API_HEADER=

_cleanup_gh_api_header() { rm -f "$_GH_API_HEADER"; unset _GH_API_HEADER; }

github_api() {
    local response
    _GH_API_HEADER="$(mktemp /tmp/dotpull-github-api-header-XXXXXX.json)"
    _trap_enter _cleanup_gh_api_header
    response="$(curl -sSLD "$_GH_API_HEADER" "${_API_URL}${1}")"
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
    _trap_exit _cleanup_gh_api_header
    echo "$response"
}

_get_playbooks_from_head() {
    local head_sha
    head_sha="$(github_api /commits | _python 'import json,sys; print(json.loads(sys.stdin.read())[0]["commit"]["tree"]["sha"])')" || return

    github_api "/git/trees/$head_sha" | _python '
import json,sys
is_yml = lambda p: p.endswith(".yml") or p.endswith(".yaml")
data = json.loads(sys.stdin.read())
for x in data["tree"]:
    p = x["path"]
    if is_yml(p): print(p)
'
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
    [ -n "$DID_FETCH_PLAYBOOKS" ] && return

    start_spinner github 'Fetching playbooks'

    local playbooks name
    playbooks="$(_get_playbooks_from_head 2>&1)" || err "$playbooks"

    while read name; do
        PLAYBOOKS+=( "$name" )
    done <<< "$playbooks"

    stop_spinner

    DID_FETCH_PLAYBOOKS=1
}

validate_playbook() {
    local choice="$1" pb; shift

    get_playbook_list

    for pb in "${PLAYBOOKS[@]}"; do
        [ "$pb" = "$choice" ] && return
    done

    err "playbook must be one of: ${PLAYBOOKS[@]}"
}

_cleanup_color_prompt() { printf -- "$RESET\n" >&2; }

select_playbook() {
    local i selection

    get_playbook_list
    set -- "${PLAYBOOKS[@]}"

    printf '\n'

    while true; do
        echo 'Select a playbook:' >&2
        echo '==================' >&2
        for (( i=0; i<$#; i++ )); do
            echo "  $i) ${PLAYBOOKS[$i]}" >&2
        done
        printf '\n' >&2

        _trap_enter _cleanup_color_prompt
        read -rp "${BOLD}Choice (q to quit) ${YELLOW}> " selection </dev/tty
        #           Fix stdin, see note at bottom for more info => ~~~~~~~~~
        printf "$RESET" >&2
        _trap_del _cleanup_color_prompt

        [[ $selection == q ]] && return 1
        (( 0 <= selection && selection < $# )) && break

        printf '\n' >&2
    done

    printf '\n'

    PLAYBOOK_CHOICE="${PLAYBOOKS[$selection]}"
}

install_packages() {
    case "$OS_ID_LIKE" in
        *rhel*) yum_install "$@" ;;
        *debian*) apt_install "$@" ;;
        *) err "unsupported OS: $os_name"
    esac
}

apt_install() {
    local pkg did_update
    for pkg in "$@"; do
        if dpkg -s "$pkg" &>/dev/null; then
            info_nl apt "Package installed: $pkg $CHECK_MARK"
        else
            if [ -z "$did_update" ]; then
                start_spinner apt 'Updating package index'
                if ! sudo apt update -y &>/dev/null; then
                    err "apt: unable to update"
                fi
                stop_spinner
                did_update=1
            fi
            start_spinner apt "Installing $pkg"
            if ! sudo apt install -y "$pkg" &>/dev/null; then
                err "apt: unable to install package: $pkg"
            fi
            stop_spinner
        fi
    done
}

yum_install() {
    local pkg did_update
    for pkg in "$@"; do
        if rpm -q "$pkg" &>/dev/null; then
            info_nl yum "Package installed: $pkg $CHECK_MARK"
        else
            start_spinner yum "Installing $pkg"
            if ! yum install -y "$pkg" &>/dev/null; then
                err "yum: unable to install package: $pkg"
            fi
            stop_spinner
        fi
    done
}

install_uv() {
    local uv_installed
    if [ -x "$HOME/.local/bin/uv" ]; then
        info_nl uv "Installed $CHECK_MARK"
    else
        start_spinner uv 'Installing'
        local uv_releases uv_download_url
        if ! uv_releases="$(curl -ksSLf https://api.github.com/repos/astral-sh/uv/releases)"; then
            err 'uv: failed to get releases'
        fi
        if ! uv_download_url="$(python3 -c '
import sys, json
releases = json.load(sys.stdin)
assets = releases[0]["assets"]
installer_asset = next(a for a in assets if a["name"] == "uv-installer.sh")
print(installer_asset["browser_download_url"])
        ' <<< "$uv_releases")"; then
            err 'uv: failed to find latest release'
        fi
        if ! curl -sSLf "$uv_download_url" | UV_NO_MODIFY_PATH=1 sh - &>/dev/null; then
            err 'uv: failed to install'
        fi
        stop_spinner
    fi
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

ANSIBLE_HOME=/tmp/ansible
ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote/tmp

_setup_ansible_dirs() {
    # When the remote temporary directory does not exist Ansible will create it
    # with mode `0700`. This is a problem when a task specifies a non-root
    # `become_user` as they will not have access to it. Create the dir before
    # Ansible runs to ensure it has the appropriate permissions.
    mkdir -p "$ANSIBLE_REMOTE_TEMP"
    chmod -R 0777 "$ANSIBLE_REMOTE_TEMP"
}

_cleanup_ansible_dirs() { rm -rf "$ANSIBLE_HOME" "$ANSIBLE_REMOTE_TEMP"; }

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage ;;
            *) [ -n "$PLAYBOOK_CHOICE" ] && usage 1 || PLAYBOOK_CHOICE="$1" ;;
        esac
        shift
    done

    local -a packages=(curl git gnupg2)

    get_os_info
    case "$OS_ID_LIKE" in
        *debian*) packages+=(python3 python3-pip python3-apt) ;;
    esac

    # Install package dependencies
    install_packages "${packages[@]}"

    install_uv
    PATH="$HOME/.local/bin:$PATH"

    # Validate the given playbook or have user choose one
    if [ -n "$PLAYBOOK_CHOICE" ]; then
        if in_self && [ -f "$PLAYBOOK_CHOICE" ]; then
            # In self repo and the playbook file exists, no need to fetch
            # playbooks from the GitHub API or validate.
            :
        else
            validate_playbook "$PLAYBOOK_CHOICE"
        fi
    else
        select_playbook || return 0
    fi

    local title="Executing playbook: $PLAYBOOK_CHOICE"
    printf "\n${GREEN}${BOLD}"
    echo "  ▐▛▀$(printf "▀%.0s" $(seq ${#title}))▀▜▌"
    echo "  ▐▌ ${title} ▐▌"
    echo "  ▐▙▄$(printf "▄%.0s" $(seq ${#title}))▄▟▌"
    printf "${RESET}\n"

    _setup_ansible_dirs
    _trap_enter _cleanup_ansible_dirs

    ANSIBLE_PYTHON_INTERPRETER="$(which python3)" \
    ANSIBLE_NOCOWS=true \
    ANSIBLE_FORCE_COLOR=true \
    ANSIBLE_RETRY_FILES_ENABLED=false \
    ANSIBLE_DEPRECATION_WARNINGS=false \
    ANSIBLE_HOME="$ANSIBLE_HOME" \
    ANSIBLE_REMOTE_TMP="$ANSIBLE_REMOTE_TEMP" \
    uv run \
        ansible-pull -U "$REPO_URL" --purge "$PLAYBOOK_CHOICE" \
        -c local -i localhost, -l localhost \
        --ask-become-pass \
        </dev/tty
    #   ~~~~~~~~~
    #   ^ Fix stdin for ansible
    #
    # NOTE: This script is intended to be run as `curl ... | sudo bash -` which
    # causes problems when we want to read from stdin in this script (e.g. with
    # `read`) or in ansible (e.g. with `vars_promp`). This is fixed by
    # redirecting the tty (`/dev/tty`) of this process to stdin of the process
    # that needs it.

    _trap_exit _cleanup_ansible_dirs
}

# endregion

main "$@"
