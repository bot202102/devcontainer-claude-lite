#!/bin/bash
# Runs on every container start. Fixes common Docker Desktop issues + cargo env.
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

# Fix: Docker socket GID from host may not match container's docker group GID.
# Without this, `docker` commands require sudo despite user being in docker group.
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  CUR_GID=$(getent group docker | cut -d: -f3)
  if [ "$SOCK_GID" != "$CUR_GID" ]; then
    echo "[post-start] Fixing docker socket access (socket GID=$SOCK_GID, docker group GID=$CUR_GID)..."
    sudo chmod 666 /var/run/docker.sock
  fi
fi

# Bind-mounted workspaces may have different uid — mark as safe
git config --global safe.directory /workspace 2>/dev/null || true

# Ensure Rust toolchain is on PATH for interactive shells
. "$HOME/.cargo/env" 2>/dev/null || true

# Optional: warn if cargo target/ is on the bind-mount instead of the named volume
# (named volume should be at /workspace/rust/target — only relevant if rust/ exists)
if [ -d /workspace/rust ] && [ ! -L /workspace/rust/target ] && [ -d /workspace/rust/target ]; then
  TARGET_FS=$(stat -f -c %T /workspace/rust/target 2>/dev/null || echo "unknown")
  if [ "$TARGET_FS" != "ext2/ext3" ] && [ "$TARGET_FS" != "tmpfs" ]; then
    echo "[post-start] WARNING: rust/target/ may be on bind-mount, expect slow builds"
  fi
fi
