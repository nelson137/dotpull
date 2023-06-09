#!/usr/bin/env bash

set -eo pipefail

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

python_venv_installed() {
    dpkg -l 2>/dev/null \
      | awk '$2=="python3.10-venv"{s=$1;exit} END{if(s=="ii") exit 0; exit 1}'
}

if [ -n "$USE_VENV" ]; then
    if !python_venv_installed; then
        sudo apt update
        sudo apt install -y --no-install-recommends python3.10-venv
    fi

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
sudo mkdir -p "$ANSIBLE_REMOTE_TEMP"
sudo chmod -R 0777 "$ANSIBLE_REMOTE_TEMP"

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
