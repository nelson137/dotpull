#!/usr/bin/env bash

HERE="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"
REPO="$(dirname "$HERE")"
cd "$REPO"
unset HERE REPO

deploy() {
    rsync -rl --exclude=.git/ "$@"
}

if [[ -n $1 ]]; then
    TARGET="$1"; shift
    [[ -d $TARGET ]] && TARGET="${TARGET%%/}/"
    deploy "$TARGET" "lightbug:~/dotpull/$TARGET" "$@"
else
    deploy ./ 'lightbug:~/dotpull' "$@"
fi
