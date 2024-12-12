#!/usr/bin/env bash

set -eo pipefail

declare PLAYBOOK
declare -a ANSIBLE_ARGS

while (( $# > 0 )); do
    if [ -n "$PLAYBOOK" ]; then
        ANSIBLE_ARGS+=( "$1" )
    else
        case "$1" in
            *) PLAYBOOK="$1" ;;
        esac
    fi
    shift
done

if [ -z "$PLAYBOOK" ]; then
    echo "Usage: $0 PLAYBOOK [ANSIBLE_ARGS...]" >&2
    exit 1
fi

if [ ! -x "$HOME/.local/bin/uv" ]; then
    # Install uv
    declare UV_RELEASES UV_DOWNLOAD_URL
    UV_RELEASES="$(curl -ksSLf https://api.github.com/repos/astral-sh/uv/releases)"
    UV_DOWNLOAD_URL="$(python3 -c '
import sys, json
releases = json.load(sys.stdin)
assets = releases[0]["assets"]
installer_asset = next(a for a in assets if a["name"] == "uv-installer.sh")
print(installer_asset["browser_download_url"])
    ' <<< "$UV_RELEASES")"
    curl -sSLf "$UV_DOWNLOAD_URL" | sh -
    unset UV_RELEASES UV_DOWNLOAD_URL
fi

ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote/tmp
if [ ! -d "$ANSIBLE_REMOTE_TEMP" ]; then
    mkdir -p "$ANSIBLE_REMOTE_TEMP"
    chmod -R 0777 "$ANSIBLE_REMOTE_TEMP"
fi

ANSIBLE_NOCOWS=true \
ANSIBLE_NOCOLOR=false \
ANSIBLE_RETRY_FILES_ENABLED=false \
ANSIBLE_DEPRECATION_WARNINGS=false \
ANSIBLE_HOME=/tmp/ansible \
ANSIBLE_REMOTE_TMP="$ANSIBLE_REMOTE_TEMP" \
uv run ansible-playbook \
    -c local -i localhost, -l localhost \
    --ask-become-pass \
    "$PLAYBOOK" \
    "$@"
