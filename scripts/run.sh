#!/usr/bin/env bash

set -eo pipefail

PLAYBOOK="${1:-nelsonearle.com.yml}"; shift || :

if dpkg -l 2>/dev/null | awk '$2=="python3.10-venv"{s=$1;exit} END{exit s=="ii"}'; then
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

ANSIBLE_PYTHON_INTERPRETER="$(which python3)" \
ANSIBLE_NOCOWS=true \
ANSIBLE_NOCOLOR=false \
ANSIBLE_RETRY_FILES_ENABLED=false \
ANSIBLE_DEPRECATION_WARNINGS=false \
ANSIBLE_HOME=/tmp/ansible \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote/tmp \
ansible-playbook \
    -c local -i localhost, -l localhost \
    "$PLAYBOOK" \
    "$@"
