#!/usr/bin/env bash

cd "$(dirname "${BASH_SOURCE[0]}")"

sudo rm -rf ~{root,ubuntu}/.ansible

curl -sSL https://github.com/nelson137/dotpull/raw/master/install.sh \
  | sudo bash -
