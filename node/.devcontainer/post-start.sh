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

# Fix: node_modules may have wrong ownership from host or previous root build.
# This prevents pnpm/npm from failing with EACCES on install or update.
if [ -d /workspace/node_modules ] && [ "$(stat -c '%u' /workspace/node_modules 2>/dev/null)" != "$(id -u)" ]; then
  echo "[post-start] node_modules has wrong owner ($(stat -c '%u' /workspace/node_modules) != $(id -u)). Removing..."
  sudo rm -rf /workspace/node_modules
  echo "[post-start] Removed stale node_modules. Running install..."
  if [ -f /workspace/pnpm-lock.yaml ]; then
    cd /workspace && pnpm install
  elif [ -f /workspace/package-lock.json ]; then
    cd /workspace && npm ci
  elif [ -f /workspace/package.json ]; then
    cd /workspace && npm install
  fi
fi

# Fix: Docker socket GID from host may not match container's docker group GID.
# Without this, `docker` commands require sudo despite user being in docker group.
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  CUR_GID=$(getent group docker | cut -d: -f3)
  if [ "$SOCK_GID" != "$CUR_GID" ]; then
    echo "[post-start] Fixing docker group GID ($CUR_GID -> $SOCK_GID) to match host socket..."
    sudo groupmod -g "$SOCK_GID" docker 2>/dev/null || true
  fi
fi

# Bind-mounted workspaces may have different uid — mark as safe
git config --global safe.directory /workspace 2>/dev/null || true
