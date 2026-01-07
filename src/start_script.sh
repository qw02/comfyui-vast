#!/usr/bin/env bash
set -e

REPO_URL="https://github.com/qw02/comfyui-vast.git"
REPO_DIR="/opt/comfyui-vast"

if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
else
    git -C "$REPO_DIR" pull
fi

exec bash "$REPO_DIR/src/start_script.sh"