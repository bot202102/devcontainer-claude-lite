#!/bin/bash
# Runs on HOST before container build (initializeCommand).
# Cleans stale VS Code Server from Docker Desktop WSL VM.
#
# Problem: Docker Desktop's docker-desktop WSL distro has a tiny 136MB root
# filesystem. VS Code Dev Containers stages a ~62MB node binary there at
# /root/.vscode-remote-containers/bin/ before copying it into the container.
# Old installations accumulate and cause "No space left on device" on rebuild.

if command -v wsl.exe >/dev/null 2>&1; then
  echo "[initialize] Cleaning old VS Code Server from docker-desktop VM..."
  wsl.exe -d docker-desktop -- rm -rf /root/.vscode-remote-containers/bin/ 2>/dev/null || true
fi
