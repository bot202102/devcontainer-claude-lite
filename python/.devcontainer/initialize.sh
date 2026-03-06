#!/bin/bash
# Manual cleanup script for Docker Desktop WSL VM.
# The devcontainer.json initializeCommand handles this automatically via array form,
# but this script is useful for manual execution when the first rebuild fails.
#
# Problem: Docker Desktop's docker-desktop WSL distro has a tiny 136MB root
# filesystem. VS Code Dev Containers stages a ~62MB node binary at
# /root/.vscode-remote-containers/bin/ before copying it into the container.
# Old installations accumulate and cause "No space left on device" on rebuild.
#
# LIMITATION: VS Code attempts the WSL install BEFORE initializeCommand runs,
# so initializeCommand only cleans residuals for the NEXT rebuild attempt.
# On first failure, run this script manually:
#   wsl -d docker-desktop -- rm -rf /root/.vscode-remote-containers /root/.vscode-server
#
# Usage (from Windows host):
#   bash .devcontainer/initialize.sh
#   # or directly:
#   wsl -d docker-desktop -- rm -rf /root/.vscode-remote-containers/bin/ /root/.vscode-server/

if command -v wsl.exe >/dev/null 2>&1; then
  echo "[initialize] Cleaning old VS Code Server from docker-desktop VM..."
  wsl.exe -d docker-desktop -- rm -rf /root/.vscode-remote-containers/bin/ /root/.vscode-server/ 2>/dev/null || true
elif command -v wsl >/dev/null 2>&1; then
  echo "[initialize] Cleaning old VS Code Server from docker-desktop VM..."
  wsl -d docker-desktop -- rm -rf /root/.vscode-remote-containers/bin/ /root/.vscode-server/ 2>/dev/null || true
else
  echo "[initialize] Not on Windows/WSL — skipping Docker Desktop VM cleanup."
fi
