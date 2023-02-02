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
# SPINNER
##################################################

# region spinner

SPINNER='|/-\'
SPINNER_PID=

# Make sure spinner doesn't get left running
trap '_quiet_kill "$SPINNER_PID"' EXIT HUP ABRT

_quiet_kill() {
    kill -9 "$@" &>/dev/null || true
    wait "$@" &>/dev/null || true
}

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
}

stop_spinner() {
    _quiet_kill "$SPINNER_PID"
    SPINNER_PID=
    tput rc
    printf '\e[0K%s\n' "$*"
}

# endregion

##################################################
# GITHUB API
##################################################

# region github api

USER='nelson137'
REPO='dotpull'
API_URL="https://api.github.com/repos/$USER/$REPO"

github_api() {
    local header response
    header="$(mktemp /tmp/github-api-header-XXXXXX.json)"
    trap "rm -f '$header'" EXIT
    response="$(curl -sSLD "$header" "${API_URL}${1}")"
    if echo "$response" | grep -q 'API rate limit exceeded'; then
        awk -v IGNORECASE=1 '
            /^X-Ratelimit-Reset:/{
                print "error: github: rate limit met, will reset at",
                    strftime("%Y-%m-%d %I:%M:%S %P", $2)
                exit 1
            }
        ' "$header" >&2
        exit 1
    fi
    trap EXIT # clear trap
    echo "$response"
}

_get_playbooks_from_head() {
    local head_sha
    head_sha="$(github_api /commits | jq -r '.[0].commit.tree.sha')"

    github_api "/git/trees/$head_sha" | jq -r '
        def is_yaml: endswith(".yml") or endswith(".yaml");
        .tree | map(.path)[] | select(is_yaml)
    '
}

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

        printf "${BOLD}Choice (q to quit) ${YELLOW}> " >&2
        # Can't use `read -p` because stderr was redirected to /dev/null
        # Redirect in /dev/tty so this script works even when piped into bash
        read -r selection </dev/tty
        printf "$RESET" >&2

        [[ $selection == q ]] && return 1
        (( 0 <= selection && selection < $# )) && break

        printf '\n' >&2
    done

    echo "${books[$selection]}"
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
    install_packages curl git jq

    get_playbook_list

    # Validate the given playbook or have user choose one
    if [ -n "$PLAYBOOK_CHOICE" ]; then
        validate_playbook "$PLAYBOOK_CHOICE" "${PLAYBOOKS[@]}"
    else
        printf '\n'
        PLAYBOOK_CHOICE="$(select_playbook "${PLAYBOOKS[@]}")" || return 0
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
    pip3_install ansible docker

    local title="Executing playbook: $PLAYBOOK_CHOICE"
    printf "\n${GREEN}${BOLD}"
    echo "  ▐▛▀$(printf "▀%.0s" $(seq ${#title}))▀▜▌"
    echo "  ▐▌ ${title} ▐▌"
    echo "  ▐▙▄$(printf "▄%.0s" $(seq ${#title}))▄▟▌"
    printf "${RESET}\n"

    curl -sSL "$INVENTORY_URL" -o "$TEMP_INVENTORY_FILE"
    trap "rm -f '$TEMP_INVENTORY_FILE'" EXIT INT QUIT TERM

    ANSIBLE_PYTHON_INTERPRETER="$(which python3)" \
    ANSIBLE_NOCOWS=true \
    ANSIBLE_NOCOLOR=false \
    ANSIBLE_RETRY_FILES_ENABLED=false \
        exec ansible-pull -U "$REPO_URL" --purge "$PLAYBOOK_CHOICE" \
            --ask-become-pass --vault-id=@prompt -i "$TEMP_INVENTORY_FILE" \
            -c local
}

# endregion

main "$@"
