#!/usr/bin/env bash

set -eo pipefail

if [ ! "$EUID" = 0 ]; then
    exec sudo "$0" "$@"
fi

declare USE_VENV PLAYBOOK
declare -a ANSIBLE_ARGS

while (( $# > 0 )); do
    if [ -n "$PLAYBOOK" ]; then
        ANSIBLE_ARGS+=( "$1" )
    else
        case "$1" in
            --venv) USE_VENV=1 ;;
            *) PLAYBOOK="$1" ;;
        esac
    fi
    shift
done

if [ -z "$PLAYBOOK" ]; then
    echo "Usage: $0 [--venv] PLAYBOOK [ANSIBLE_ARGS...]" >&2
    exit 1
fi

dpkg_is_installed() {
    local pkg="$1"
    dpkg -l "$pkg" 2>/dev/null \
      | awk -v pkg="$pkg" '$2==pkg{x=$1=="ii";exit} END{exit !x}'
}

if [ -n "$USE_VENV" ]; then
    apt update
    for pkg in python3.12-venv; do
        if ! dpkg_is_installed "$pkg"; then
            apt install -y --no-install-recommends "$pkg"
        fi
    done

    VENV='/tmp/venv'

    if [ -d "$VENV" ]; then
        source "$VENV/bin/activate"
    else
        python3 -m venv "$VENV"
        source "$VENV/bin/activate"
        pip3 install ansible
    fi
fi

ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote/tmp
if [ ! -d "$ANSIBLE_REMOTE_TEMP" ]; then
    mkdir -p "$ANSIBLE_REMOTE_TEMP"
    chmod -R 0777 "$ANSIBLE_REMOTE_TEMP"
fi

ANSIBLE_PYTHON_INTERPRETER="$(which python3)" \
ANSIBLE_NOCOWS=true \
ANSIBLE_NOCOLOR=false \
ANSIBLE_RETRY_FILES_ENABLED=false \
ANSIBLE_DEPRECATION_WARNINGS=false \
ANSIBLE_HOME=/tmp/ansible \
ANSIBLE_REMOTE_TMP="$ANSIBLE_REMOTE_TEMP" \
ansible-playbook \
    -c local -i localhost, -l localhost \
    "$PLAYBOOK" \
    "$@"
