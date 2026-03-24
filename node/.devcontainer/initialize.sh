#!/bin/bash
# Cleanup old VS Code Server installations from Docker Desktop WSL VM.
# Only applies when using Docker Desktop (not Docker Engine on Ubuntu).
# Safe to skip — the error is cosmetic.

if command -v wsl.exe >/dev/null 2>&1 && wsl.exe -l -q 2>/dev/null | grep -qi docker-desktop; then
  echo "[initialize] Cleaning old VS Code Server from docker-desktop VM..."
  wsl.exe -d docker-desktop -- rm -rf /root/.vscode-remote-containers/bin/ /root/.vscode-server/ 2>/dev/null || true
elif command -v wsl >/dev/null 2>&1 && wsl -l -q 2>/dev/null | grep -qi docker-desktop; then
  echo "[initialize] Cleaning old VS Code Server from docker-desktop VM..."
  wsl -d docker-desktop -- rm -rf /root/.vscode-remote-containers/bin/ /root/.vscode-server/ 2>/dev/null || true
else
  echo "[initialize] Docker Engine (no Docker Desktop VM) — skipping cleanup."
fi
