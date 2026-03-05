#!/bin/bash
# Runs on every container start. Fixes common Docker Desktop issues.
set -e

# Fix: Docker Desktop on Windows mounts ~/.gitconfig as a directory
# when it doesn't exist on the host. Redirect git to a real file.
# See: https://github.com/microsoft/vscode-remote-release/issues/863
if [ -d "$HOME/.gitconfig" ]; then
  REAL="$HOME/.gitconfig.real"
  touch "$REAL"
  export GIT_CONFIG_GLOBAL="$REAL"

  LINE='export GIT_CONFIG_GLOBAL="$HOME/.gitconfig.real"'
  grep -qF 'GIT_CONFIG_GLOBAL' ~/.zshrc 2>/dev/null || \
    sed -i "1a\\$LINE" ~/.zshrc
fi

# Bind-mounted workspaces may have different uid — mark as safe
git config --global safe.directory /workspace 2>/dev/null || true
