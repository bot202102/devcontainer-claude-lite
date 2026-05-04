# Python+Rust Devcontainer Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `python-rust/` template to `bot202102/devcontainer-claude-lite` that provides a Python 3.13 + Rust stable hybrid devcontainer with audio system libraries preinstalled, ready for projects that need both languages.

**Architecture:** Mirrors the existing `python/` template's structure (Dockerfile + devcontainer.json + docker-compose.yml + initialize.sh + post-start.sh + setup-hooks.sh) but adds rustup/cargo (taken from `gainshield/.devcontainer/Dockerfile`), audio libraries (ffmpeg + libsndfile + libsox-fmt-all), and persistent volumes for HuggingFace/Torch model caches. devcontainer.json combines Python + Rust extensions. setup-hooks.sh runs ruff (Python) + clippy/rustfmt (Rust) on staged files only at commit time.

**Tech Stack:** Python 3.13-slim, rustup stable + clippy + rustfmt + rust-analyzer, uv, Node 22 (for Claude Code), Chromium (Chrome DevTools MCP), ffmpeg, libsndfile, libsox-fmt-all, zsh, Docker CLI via host socket.

**Repo / branch:**
- Repo: `bot202102/devcontainer-claude-lite` (PRIVATE upstream, default branch `master` — note: NOT `main`)
- Local clone: `/home/rpach/Programacion/devcontainer-claude-lite`
- Working branch: `feat/python-rust-template` (already created)
- Target PR base: `master`

**Spec reference:** `bot202102/audio-a-texto:docs/superpowers/specs/2026-05-04-audio-a-texto-devcontainer-design.md` §4

---

## File Structure

All paths relative to the `devcontainer-claude-lite` repo root.

**Create:**
```
python-rust/
├── README.md                          # When to use this vs python/ vs node/
└── .devcontainer/
    ├── Dockerfile                     # Python 3.13-slim base + rustup + audio libs
    ├── devcontainer.json              # Python + Rust extensions, dockerComposeFile mode
    ├── docker-compose.yml             # app service + commented optional services
    ├── initialize.sh                  # VS Code Server cleanup (Docker Desktop)
    ├── post-start.sh                  # gitconfig fix + docker.sock perms + cargo env
    └── setup-hooks.sh                 # pre-commit: ruff (py) + clippy/rustfmt (rust)
```

**Modify:**
- `README.md` (repo root) — add `python-rust/` row to the stacks table.

**No tests in this PR** beyond manual smoke verification. The template is config files; the verification is "the devcontainer builds and the resulting container has all the expected tools at the expected versions". Two of the tasks below are dedicated to that smoke check.

---

## Task 1: Verify branch state and that the plan is committed

**Files:** none (verification only)

The plan file (this document) is expected to already be committed on branch `feat/python-rust-template` as commit "docs: plan for python-rust template". Verify before starting implementation.

- [ ] **Step 1: Confirm branch and clean tree**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
git status
git branch --show-current
git log --oneline -2
```

Expected:
```
On branch feat/python-rust-template
nothing to commit, working tree clean
```
```
feat/python-rust-template
```
```
<sha>  docs: plan for python-rust template
8e4eff5 fix(guardrails/python): O(N²) hang + framework decorator false-positives (#22)
```

If the working tree is dirty or the plan commit is missing, stop and reconcile.

---

## Task 2: Create directory skeleton

**Files:**
- Create: `python-rust/` (directory)
- Create: `python-rust/.devcontainer/` (directory)

- [ ] **Step 1: Create directories**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
mkdir -p python-rust/.devcontainer
ls -la python-rust/
ls -la python-rust/.devcontainer/
```

Expected: both directories exist and are empty.

- [ ] **Step 2: Verify against spec**

```bash
test -d python-rust/.devcontainer && echo "OK"
```

Expected: `OK`.

---

## Task 3: Create Dockerfile

**Files:**
- Create: `python-rust/.devcontainer/Dockerfile`

- [ ] **Step 1: Write Dockerfile**

Create `python-rust/.devcontainer/Dockerfile` with the following exact content:

```dockerfile
FROM python:3.13-slim

ARG TZ
ENV TZ="$TZ"

# Essential system tools + audio libs + Chromium + Playwright deps
# Build essentials: native compilation (cpal, ALSA, Pillow, etc.)
# Audio libs: ffmpeg + libsndfile + libsox-fmt-all for pydub / symphonia / soundfile
# Chromium: full browser for Chrome DevTools MCP (browser automation, screenshots)
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  zsh \
  gh \
  jq \
  nano \
  ca-certificates \
  curl \
  pkg-config \
  build-essential \
  libssl-dev \
  libasound2-dev \
  ffmpeg \
  libsndfile1 \
  libsox-fmt-all \
  chromium \
  libnss3 \
  libatk1.0-0 \
  libatk-bridge2.0-0 \
  libcups2 \
  libdrm2 \
  libxkbcommon0 \
  libxcomposite1 \
  libxdamage1 \
  libxfixes3 \
  libxrandr2 \
  libgbm1 \
  libpango-1.0-0 \
  libcairo2 \
  libasound2 \
  libatspi2.0-0 \
  libxshmfence1 \
  fonts-liberation \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 22 (Claude Code requires modern Node)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
  apt-get install -y --no-install-recommends nodejs && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Docker CLI (uses host's Docker via socket)
RUN install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user
ARG USERNAME=dev
RUN useradd -m -s /bin/zsh $USERNAME && \
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME && \
  groupadd -f docker && usermod -aG docker $USERNAME

# Persist shell history
RUN mkdir /commandhistory && \
  touch /commandhistory/.zsh_history && \
  chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/$USERNAME/.claude /home/$USERNAME/.vscode-server && \
  chown -R $USERNAME:$USERNAME /workspace /home/$USERNAME/.claude /home/$USERNAME/.vscode-server

WORKDIR /workspace

# uv (fast Python package installer)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

USER $USERNAME

# Rust toolchain (rustup + stable)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
  . "$HOME/.cargo/env" && \
  rustup component add clippy rustfmt rust-analyzer

# Python: no virtualenv needed in container
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV UV_SYSTEM_PYTHON=1
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/dev/.cargo/bin:/home/dev/.local/bin

# Shell
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano
ENV LANG=C.UTF-8

# Chromium
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium

# Python env
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Persistent caches for HuggingFace / Torch models (mounted as named volumes)
ENV HF_HOME=/home/dev/.cache/huggingface
ENV TORCH_HOME=/home/dev/.cache/torch

# Minimal zsh
RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> ~/.zshrc && \
  echo 'export HISTSIZE=5000' >> ~/.zshrc && \
  echo 'export SAVEHIST=5000' >> ~/.zshrc && \
  echo 'setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY INC_APPEND_HISTORY' >> ~/.zshrc && \
  echo 'autoload -Uz compinit && compinit' >> ~/.zshrc && \
  echo 'PROMPT="%F{green}%~%f %# "' >> ~/.zshrc && \
  echo '. "$HOME/.cargo/env"' >> ~/.zshrc

# Claude Code (needs npm)
ARG CLAUDE_CODE_VERSION=latest
RUN sudo npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
```

- [ ] **Step 2: Verify file exists and is readable**

```bash
test -f python-rust/.devcontainer/Dockerfile && wc -l python-rust/.devcontainer/Dockerfile
```

Expected: line count ~110 lines.

---

## Task 4: Create devcontainer.json

**Files:**
- Create: `python-rust/.devcontainer/devcontainer.json`

- [ ] **Step 1: Write devcontainer.json**

Create `python-rust/.devcontainer/devcontainer.json` with the following exact content:

```jsonc
{
  "name": "Python+Rust",
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
  "workspaceFolder": "/workspace",
  "shutdownAction": "stopCompose",
  "userEnvProbe": "none",
  "initializeCommand": "bash .devcontainer/initialize.sh",
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "ms-python.python",
        "rust-lang.rust-analyzer",
        "tamasfe.even-better-toml",
        "serayuzgur.crates"
      ],
      "settings": {
        "terminal.integrated.defaultProfile.linux": "zsh",
        "terminal.integrated.profiles.linux": {
          "zsh": {
            "path": "zsh"
          }
        },
        "python.defaultInterpreterPath": "/usr/local/bin/python",
        "python.languageServer": "None",
        "rust-analyzer.check.command": "clippy",
        "rust-analyzer.check.extraArgs": ["--", "-D", "warnings"],
        "editor.formatOnSave": false,
        "editor.codeActionsOnSave": {},
        "files.eol": "\n",
        "files.exclude": {
          "**/__pycache__": true,
          "**/*.pyc": true,
          "**/.pytest_cache": true,
          "**/.mypy_cache": true,
          "**/.ruff_cache": true,
          "**/target": true
        },
        "files.watcherExclude": {
          "**/__pycache__/**": true,
          "**/.git/objects/**": true,
          "**/.git/subtree-cache/**": true,
          "**/.mypy_cache/**": true,
          "**/.ruff_cache/**": true,
          "**/.pytest_cache/**": true,
          "**/target/**": true,
          "**/data/**": true
        },
        "search.exclude": {
          "**/__pycache__": true,
          "**/.mypy_cache": true,
          "**/.ruff_cache": true,
          "**/.pytest_cache": true,
          "**/target": true,
          "**/data": true
        }
      }
    }
  },
  "remoteUser": "dev",
  "containerEnv": {
    "PYTHONUNBUFFERED": "1",
    "ENVIRONMENT": "development",
    "SHELL": "/bin/zsh",
    "CLAUDE_CONFIG_DIR": "/home/dev/.claude"
  },
  "postCreateCommand": "test -f python/pyproject.toml && (cd python && sudo uv pip install --system -e .) || (test -f requirements.txt && sudo uv pip install --system -r requirements.txt) || echo 'No Python deps to install'",
  "postStartCommand": "bash .devcontainer/post-start.sh"
}
```

- [ ] **Step 2: Validate JSON syntax**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
python3 -c "import json; json.load(open('python-rust/.devcontainer/devcontainer.json'))" && echo "JSON OK"
```

Expected: `JSON OK`. (devcontainer.json is jsonc; json5 wouldn't parse `// comments` but this file has none — it parses as plain JSON.)

---

## Task 5: Create docker-compose.yml

**Files:**
- Create: `python-rust/.devcontainer/docker-compose.yml`

- [ ] **Step 1: Write docker-compose.yml**

Create `python-rust/.devcontainer/docker-compose.yml` with the following exact content:

```yaml
# =============================================================================
# Docker Compose for Python+Rust hybrid devcontainer
# =============================================================================
# Usage:
#   1. Default: builds the app service from .devcontainer/Dockerfile and runs
#      the container in workspace bind-mount mode.
#   2. To enable additional services (postgres, redis, qdrant, etc.) uncomment
#      the relevant block below + the matching `depends_on:` and `environment:`
#      entries in the `app` service.
#
# Or use standalone (without devcontainer integration):
#   docker compose -f .devcontainer/docker-compose.yml up -d
#
# IMPORTANT: Dev Containers features break COPY in Dockerfiles (the CLI
# overrides the build context). Python deps are installed via postCreateCommand
# for the app service. Rust deps via postCreateCommand or on-demand cargo build.
# Worker services must install deps at startup — see the worker example below.
#
# PORT CONFLICTS: If you run multiple devcontainers simultaneously, use unique
# port ranges per project via env vars in .devcontainer/.env. Example:
#   POSTGRES_PORT=31432
#   REDIS_PORT=31379
# Default ports (5432, 6379, etc.) WILL conflict with other containers.
# =============================================================================

services:
  app:
    build:
      context: ..
      dockerfile: .devcontainer/Dockerfile
      args:
        TZ: ${TZ:-America/Lima}
        CLAUDE_CODE_VERSION: latest
    volumes:
      - ..:/workspace:cached
      - pyrust-history:/commandhistory
      - pyrust-claude-config:/home/dev/.claude
      - pyrust-cargo-registry:/home/dev/.cargo/registry
      - pyrust-cargo-git:/home/dev/.cargo/git
      - pyrust-target:/workspace/rust/target
      - pyrust-hf-cache:/home/dev/.cache/huggingface
      - pyrust-torch-cache:/home/dev/.cache/torch
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - seccomp=unconfined
    command: sleep infinity
    healthcheck:
      test: ["CMD-SHELL", "getent hosts google.com > /dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    # env_file:
    #   - ../.env
    # depends_on:
    #   postgres:
    #     condition: service_healthy
    #   redis:
    #     condition: service_healthy

  ## ---------------------------------------------------------
  ## PostgreSQL — uncomment to enable
  ## Use pgvector/pgvector:pg17 if your app needs vector search
  ## ---------------------------------------------------------
  # postgres:
  #   image: postgres:17-alpine
  #   restart: unless-stopped
  #   environment:
  #     POSTGRES_USER: devuser
  #     POSTGRES_PASSWORD: devpass
  #     POSTGRES_DB: devdb
  #   volumes:
  #     - pgdata:/var/lib/postgresql/data
  #   ports:
  #     - "${POSTGRES_PORT:-5432}:5432"
  #   healthcheck:
  #     test: ["CMD-SHELL", "pg_isready -U devuser -d devdb"]
  #     interval: 5s
  #     timeout: 3s
  #     retries: 5

  ## ---------------------------------------------------------
  ## Redis — uncomment to enable
  ## ---------------------------------------------------------
  # redis:
  #   image: redis:7-alpine
  #   restart: unless-stopped
  #   command: redis-server --requirepass devpass --maxmemory 128mb --maxmemory-policy allkeys-lru
  #   volumes:
  #     - redisdata:/data
  #   ports:
  #     - "${REDIS_PORT:-6379}:6379"
  #   healthcheck:
  #     test: ["CMD", "redis-cli", "-a", "devpass", "ping"]
  #     interval: 5s
  #     timeout: 3s
  #     retries: 5

  ## ---------------------------------------------------------
  ## Qdrant (vector search) — uncomment to enable
  ## NOTE: qdrant/qdrant image has NO curl/wget — healthcheck
  ## uses bash /dev/tcp instead.
  ## ---------------------------------------------------------
  # qdrant:
  #   image: qdrant/qdrant:latest
  #   restart: unless-stopped
  #   volumes:
  #     - qdrantdata:/qdrant/storage
  #   ports:
  #     - "${QDRANT_PORT:-6333}:6333"
  #     - "${QDRANT_GRPC_PORT:-6334}:6334"
  #   healthcheck:
  #     test: ["CMD-SHELL", "timeout 2 bash -c 'echo > /dev/tcp/localhost/6333' || exit 1"]
  #     interval: 10s
  #     timeout: 5s
  #     retries: 5
  #     start_period: 20s

  ## ---------------------------------------------------------
  ## Minio (S3-compatible storage) — uncomment to enable
  ## ---------------------------------------------------------
  # minio:
  #   image: minio/minio:latest
  #   restart: unless-stopped
  #   command: server /data --console-address ":9001"
  #   environment:
  #     MINIO_ROOT_USER: minioadmin
  #     MINIO_ROOT_PASSWORD: minioadmin
  #   volumes:
  #     - miniodata:/data
  #   ports:
  #     - "${MINIO_PORT:-9000}:9000"
  #     - "${MINIO_CONSOLE_PORT:-9001}:9001"

  ## ---------------------------------------------------------
  ## Worker example — Python (celery / taskiq / etc.)
  ## Dev Containers features break COPY, so deps are NOT baked into the image.
  ## The worker installs them at startup via bash -c before running the command.
  ## ---------------------------------------------------------
  # worker:
  #   build:
  #     context: ..
  #     dockerfile: .devcontainer/Dockerfile
  #     args:
  #       TZ: ${TZ:-America/Lima}
  #   volumes:
  #     - ..:/workspace:cached
  #   command: bash -c "uv pip install -r requirements.txt && celery -A myapp worker --loglevel=info"
  #   env_file:
  #     - ../.env
  #   environment:
  #     PYTHONUNBUFFERED: "1"
  #     REDIS_URL: redis://:devpass@redis:6379
  #   depends_on:
  #     redis:
  #       condition: service_healthy

volumes:
  pyrust-history:
  pyrust-claude-config:
  pyrust-cargo-registry:
  pyrust-cargo-git:
  pyrust-target:
  pyrust-hf-cache:
  pyrust-torch-cache:
  # pgdata:
  # redisdata:
  # qdrantdata:
  # miniodata:
```

Note on volume names: hardcoded `pyrust-*` keys mean two projects copying this template would share volumes (cache contamination, history mix). The `python-rust/README.md` (Task 9) instructs consumers to rename the prefix at copy time, e.g. `sed -i 's/pyrust-/your-project-/g' .devcontainer/docker-compose.yml`. Same convention as `gainshield/` and `datador/` upstream.

- [ ] **Step 2: Validate compose syntax**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite/python-rust/.devcontainer
docker compose config > /dev/null && echo "Compose OK"
```

Expected: `Compose OK`.

---

## Task 6: Create initialize.sh

**Files:**
- Create: `python-rust/.devcontainer/initialize.sh`

- [ ] **Step 1: Write initialize.sh**

Create `python-rust/.devcontainer/initialize.sh` with the following exact content (identical to `python/.devcontainer/initialize.sh` — proven to work):

```bash
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x python-rust/.devcontainer/initialize.sh
ls -la python-rust/.devcontainer/initialize.sh
```

Expected: `-rwxr-xr-x` permissions.

---

## Task 7: Create post-start.sh

**Files:**
- Create: `python-rust/.devcontainer/post-start.sh`

- [ ] **Step 1: Write post-start.sh**

Create `python-rust/.devcontainer/post-start.sh` with the following exact content:

```bash
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x python-rust/.devcontainer/post-start.sh
ls -la python-rust/.devcontainer/post-start.sh
```

Expected: `-rwxr-xr-x` permissions.

---

## Task 8: Create setup-hooks.sh

**Files:**
- Create: `python-rust/.devcontainer/setup-hooks.sh`

- [ ] **Step 1: Write setup-hooks.sh**

Create `python-rust/.devcontainer/setup-hooks.sh` with the following exact content:

```bash
#!/bin/bash
# Sets up pre-commit hooks for Python + Rust.
# Runs ruff (Python) + clippy/rustfmt (Rust) ONLY on staged files at commit time.
# No background processes. Run once per project after first opening the devcontainer.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "→ Installing pre-commit (Python tool, system-wide)..."
sudo uv pip install --system pre-commit

echo "→ Writing .pre-commit-config.yaml..."

cat > .pre-commit-config.yaml <<'YAML'
# Pre-commit hooks for Python + Rust hybrid project.
# Runs only on staged files. No background processes.
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.7.4
    hooks:
      - id: ruff
        args: [--fix]
        files: ^python/.*\.py$
      - id: ruff-format
        files: ^python/.*\.py$

  - repo: local
    hooks:
      - id: cargo-fmt
        name: cargo fmt (rust/)
        entry: bash -c 'cd rust && cargo fmt -- --check'
        language: system
        files: ^rust/.*\.rs$
        pass_filenames: false
      - id: cargo-clippy
        name: cargo clippy (rust/)
        entry: bash -c 'cd rust && cargo clippy --all-targets -- -D warnings'
        language: system
        files: ^rust/.*\.(rs|toml)$
        pass_filenames: false
YAML

echo "→ Installing git hooks via pre-commit..."
pre-commit install

echo "✓ Setup complete. Pre-commit hooks active. They run on 'git commit'."
echo ""
echo "  Python checks: ruff (lint + format) on python/**/*.py"
echo "  Rust checks:   cargo fmt + clippy on rust/**/*.rs (when staged)"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x python-rust/.devcontainer/setup-hooks.sh
ls -la python-rust/.devcontainer/setup-hooks.sh
```

Expected: `-rwxr-xr-x` permissions.

---

## Task 9: Create README for the template

**Files:**
- Create: `python-rust/README.md`

- [ ] **Step 1: Write README**

Create `python-rust/README.md` with the following exact content:

````markdown
# python-rust/

Hybrid Python + Rust devcontainer template. Use when your project has (or will have, in weeks) Rust crates alongside Python code — for example, accelerating a Python hot-path with a native binary called via subprocess, or a PyO3 module.

## What's inside

| Layer | Tools |
|---|---|
| Python | 3.13-slim, uv, ruff (via setup-hooks) |
| Rust | rustup stable + clippy + rustfmt + rust-analyzer |
| Audio | ffmpeg, libsndfile1, libsox-fmt-all, libasound2-dev |
| Native build | pkg-config, libssl-dev, build-essential |
| Web (optional) | Chromium (Chrome DevTools MCP), Node 22 |
| Dev infra | Docker CLI via host socket, zsh + persistent history, Claude Code |
| Caches (volumes) | cargo registry/git, cargo target, HF_HOME, TORCH_HOME |

## When to use this template

- **`python-rust/`** — your project HAS or WILL HAVE Rust crates. The `rust/` directory and `cargo target/` volume are part of the lifecycle.
- **`python/`** — Python only. Smaller image, faster build.
- **`node/`** — Node only.

Don't pick `python-rust/` "just in case". The Rust toolchain costs ~600 MB of image size and a handful of extra apt packages.

## Layout convention

The template assumes (but does not enforce) this layout in your project:

```
your-project/
├── .devcontainer/        # copy this directory
├── python/               # Python source + pyproject.toml
└── rust/                 # Cargo workspace
    ├── Cargo.toml
    └── crates/
        └── your-crate/
```

The `docker-compose.yml` mounts `${PROJECT_NAME:-app}-target` as a volume at `/workspace/rust/target` — keeping cargo build artifacts off the bind-mount for speed.

## Usage

### 1. Copy the template

```bash
cp -r python-rust/.devcontainer your-project/
cd your-project
```

**Rename the volume prefix** to avoid cache/history collisions when multiple projects use this template simultaneously:

```bash
sed -i 's/pyrust-/your-project-/g' .devcontainer/docker-compose.yml
```

(The default prefix `pyrust-` is a placeholder. Two projects sharing it would mix cargo registry caches, shell history, and HF model caches.)

### 2. Open in VS Code

VS Code → "Reopen in Container". The first build downloads ~1.5 GB and takes 5-10 minutes (Python + Rust + Chromium). Subsequent rebuilds are mostly cached.

### 3. Set up commit-time quality gates (one-time per project)

Inside the container:

```bash
bash .devcontainer/setup-hooks.sh
```

Installs `pre-commit` and configures hooks for ruff (Python) + cargo fmt/clippy (Rust). Hooks run only on staged files at commit time. Zero background CPU.

### 4. Install your Python deps

If your project has `python/pyproject.toml`:
```bash
cd python && uv pip install -e .
```

Or with `requirements.txt` at the repo root:
```bash
uv pip install -r requirements.txt
```

The `postCreateCommand` in `devcontainer.json` does this automatically on first build (it tries `python/pyproject.toml` first, falls back to `requirements.txt` at root).

### 5. Build your Rust crates

```bash
cd rust && cargo build --release
```

To install a crate's binary into the container's PATH:
```bash
cargo install --path rust/crates/your-crate
```

## Optional services

The `docker-compose.yml` includes commented-out blocks for Postgres, Redis, Qdrant, Minio, and a Python worker service. Uncomment what you need and update `services.app.depends_on` accordingly. See the comments at the top of the file for port-conflict guidance.

## Persistent caches

Models from HuggingFace and Torch are large. The template mounts them as named volumes:

| Env var | Container path | Volume |
|---|---|---|
| `HF_HOME` | `/home/dev/.cache/huggingface` | `${PROJECT_NAME:-app}-hf-cache` |
| `TORCH_HOME` | `/home/dev/.cache/torch` | `${PROJECT_NAME:-app}-torch-cache` |
| Cargo registry | `/home/dev/.cargo/registry` | `${PROJECT_NAME:-app}-cargo-registry` |
| Cargo git | `/home/dev/.cargo/git` | `${PROJECT_NAME:-app}-cargo-git` |
| Cargo target | `/workspace/rust/target` | `${PROJECT_NAME:-app}-target` |

Models and crate dependencies survive container rebuilds.

## Compatibility

Inherits the troubleshooting fixes documented in the parent repo's [README.md](../README.md):
- WSL PATH injection (Dockerfile uses hardcoded PATH)
- Docker Desktop "No space left on device" (`initializeCommand` cleans VS Code Server residue)
- `userEnvProbe: "none"` to avoid host PATH contamination
- Network healthcheck on the `app` service to detect port-conflict-induced silent disconnects
````

- [ ] **Step 2: Verify file exists**

```bash
test -f python-rust/README.md && wc -l python-rust/README.md
```

Expected: ~110 lines.

---

## Task 10: Smoke test — Docker build

**Files:** none modified (verification only).

This task verifies the Dockerfile builds successfully. It's slow (5-10 minutes first time) but cached afterward.

- [ ] **Step 1: Build the image**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite/python-rust/.devcontainer
docker build -t pyrust-test:smoke -f Dockerfile --build-arg TZ=America/Lima ..
```

Expected: build succeeds with final line like `Successfully tagged pyrust-test:smoke` or (with buildkit) `=> exporting to image`.

If it fails:
- "Could not resolve" / network errors → check `getent hosts deb.debian.org` from a working container.
- "Unable to locate package" → run `apt-get update` is failing; check Debian mirror reachability.
- Stop on first failure and reconcile before continuing.

- [ ] **Step 2: Verify image exists**

```bash
docker image ls pyrust-test:smoke
```

Expected: a row showing the image with size ~2-2.5 GB.

---

## Task 11: Smoke test — runtime versions

**Files:** none modified (verification only).

This task verifies the container has all expected tools at expected versions.

- [ ] **Step 1: Run a container and check versions**

```bash
docker run --rm pyrust-test:smoke bash -c '
  echo "=== Python ===" && python --version
  echo "=== uv ===" && uv --version
  echo "=== Rust ===" && rustc --version && cargo --version
  echo "=== Clippy ===" && cargo clippy --version
  echo "=== rustfmt ===" && rustfmt --version
  echo "=== Node ===" && node --version
  echo "=== ffmpeg ===" && ffmpeg -version | head -1
  echo "=== libsndfile ===" && (dpkg -s libsndfile1 | grep ^Version || echo missing)
  echo "=== sox ===" && (dpkg -s libsox-fmt-all | grep ^Version || echo missing)
  echo "=== Chromium ===" && (chromium --version 2>/dev/null || echo missing)
  echo "=== Claude Code ===" && (claude --version 2>/dev/null || echo missing)
'
```

Expected:
- Python 3.13.x
- uv 0.x (any)
- rustc 1.x (stable)
- cargo 1.x
- clippy 0.1.x
- rustfmt 1.x
- Node v22.x
- ffmpeg version 5.x or 6.x
- libsndfile1 Version: 1.2.x
- libsox-fmt-all Version: 14.4.x
- Chromium 1xx.x.x.x or higher
- Claude Code: version (any)

If any tool is `missing` or returns wrong version → stop and reconcile.

- [ ] **Step 2: Verify cargo workspace can build a trivial crate**

```bash
docker run --rm pyrust-test:smoke bash -c '
  cd /tmp && cargo new --bin smoke-crate && cd smoke-crate && cargo build --release 2>&1 | tail -3
'
```

Expected: `Compiling smoke-crate v0.1.0` ... `Finished release ...`. No errors.

- [ ] **Step 3: Verify uv can install a Python package**

```bash
docker run --rm pyrust-test:smoke bash -c '
  uv pip install --system requests 2>&1 | tail -3 && python -c "import requests; print(requests.__version__)"
'
```

Expected: `requests` installs and version prints (e.g., `2.32.x`).

- [ ] **Step 4: Cleanup test image (optional)**

```bash
docker image rm pyrust-test:smoke
```

---

## Task 12: Update root README to list the new template

**Files:**
- Modify: `README.md` (repo root, the line for "Stacks disponibles" table)

- [ ] **Step 1: Read current root README stacks section**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
grep -n "Stacks disponibles" -A 6 README.md
```

Expected output (approximately):
```
9:## Stacks disponibles
10:
11:| Stack | Carpeta | Imagen base | Incluye |
12:|---|---|---|---|
13:| Node.js | `node/` | `node:22-slim` | pnpm (corepack), Node 22, Chromium (MCP) |
14:| Python | `python/` | `python:3.12-slim` | uv, Python 3.12, sqlite3, Node 22 (para Claude Code), Chromium (MCP) |
```

Note the line numbers — they may differ slightly. Use the actual line numbers from the grep output.

- [ ] **Step 2: Insert the new row after the Python row**

Use the Edit tool (or your text editor) to find this exact line in `README.md`:

```
| Python | `python/` | `python:3.12-slim` | uv, Python 3.12, sqlite3, Node 22 (para Claude Code), Chromium (MCP) |
```

And replace it with these two lines:

```
| Python | `python/` | `python:3.12-slim` | uv, Python 3.12, sqlite3, Node 22 (para Claude Code), Chromium (MCP) |
| Python+Rust | `python-rust/` | `python:3.13-slim` | uv, Python 3.13, rustup stable + clippy + rustfmt + rust-analyzer, ffmpeg + libsndfile + libsox, Node 22 (para Claude Code), Chromium (MCP) |
```

(In bash you can verify the change with `grep -A 4 "Stacks disponibles" README.md` — see step 3.)

- [ ] **Step 3: Verify the change**

```bash
grep -A 4 "Stacks disponibles" README.md
```

Expected: three data rows (Node.js, Python, Python+Rust).

---

## Task 13: Commit template files

**Files:** all created files staged together (the plan was already committed before Task 1).

- [ ] **Step 1: Stage and inspect**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
git add python-rust/ README.md
git status
git diff --cached --stat
```

Expected: 7 new files in `python-rust/` + 1 modified `README.md`. The plan doc should NOT appear here (already committed in the prior commit).

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(python-rust): add hybrid Python+Rust devcontainer template

New template at python-rust/ for projects that need both Python and Rust
in the same devcontainer. Combines the Python 3.13-slim base, uv, audio
libs (ffmpeg + libsndfile + libsox-fmt-all), Chromium for Chrome
DevTools MCP, and rustup stable with clippy/rustfmt/rust-analyzer.

The docker-compose.yml ships with named volumes for cargo
registry/git/target plus HuggingFace and Torch caches so models and
crate dependencies survive rebuilds. setup-hooks.sh wires pre-commit
hooks for ruff (Python) + cargo fmt/clippy (Rust) on staged files only.

README.md updated to list the new stack.

First consumer: bot202102/audio-a-texto (separate PR).

Refs: bot202102/audio-a-texto:docs/superpowers/specs/2026-05-04-audio-a-texto-devcontainer-design.md §4

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Verify commit**

```bash
git log --oneline -1
```

Expected: a single commit with the message above.

---

## Task 14: Push branch and open PR

**Files:** none modified.

- [ ] **Step 1: Push branch to origin**

```bash
git push -u origin feat/python-rust-template
```

Expected: branch created on remote, tracking set up.

- [ ] **Step 2: Open PR**

```bash
gh pr create --base master --title "feat(python-rust): add hybrid Python+Rust devcontainer template" --body "$(cat <<'EOF'
## Summary

- New template at \`python-rust/\` combining Python 3.13 + Rust stable + audio libs
- Audio libs (ffmpeg + libsndfile + libsox-fmt-all) preinstalled — useful for any project doing audio processing, not just the consumer
- Persistent named volumes for cargo registry/git/target + HuggingFace + Torch caches
- \`setup-hooks.sh\` wires pre-commit for ruff (Python) + cargo fmt/clippy (Rust) on staged files only
- Root README updated with the new stack

First consumer: \`bot202102/audio-a-texto\` (separate upcoming PR).

## Architecture choice

This is a SEPARATE template, not a feature flag in \`python/\`. Reasoning: rustup + cargo + audio libs add ~600 MB to the image and a non-trivial number of apt packages. Projects that don't need Rust shouldn't pay that cost. The trade-off was discussed in the design spec.

## Verification

Steps in the plan doc \`docs/superpowers/plans/2026-05-04-python-rust-template.md\`. Locally verified:
- \`docker build\` succeeds
- Container runs Python 3.13.x, rustc stable, ffmpeg, libsndfile1, libsox-fmt-all, Node 22, Chromium, Claude Code
- \`cargo new && cargo build --release\` works
- \`uv pip install requests\` works

## Test plan

- [ ] CI build passes (if any)
- [ ] Reviewer skims Dockerfile for regressions vs python/ template
- [ ] Reviewer verifies docker-compose.yml volume scoping behaves with PROJECT_NAME interpolation
- [ ] PR2 (guardrails multi-lang) and PR3 (audio-a-texto) will exercise this template end-to-end

## Related

- Design spec: bot202102/audio-a-texto:docs/superpowers/specs/2026-05-04-audio-a-texto-devcontainer-design.md
- Plan doc: docs/superpowers/plans/2026-05-04-python-rust-template.md (this PR)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: `https://github.com/bot202102/devcontainer-claude-lite/pull/N` printed.

- [ ] **Step 3: Confirm PR is open**

```bash
gh pr view --json number,state,url,headRefName
```

Expected: state OPEN, headRefName feat/python-rust-template.

---

## Definition of Done

All of the following must be true:

1. Branch `feat/python-rust-template` exists on origin and contains a single commit.
2. PR is open against `master`.
3. `python-rust/.devcontainer/` contains exactly 6 files: Dockerfile, devcontainer.json, docker-compose.yml, initialize.sh, post-start.sh, setup-hooks.sh. All shell scripts are executable.
4. `python-rust/README.md` exists with the layout convention and usage.
5. Repo root `README.md` "Stacks disponibles" table has 3 rows (Node.js, Python, Python+Rust).
6. `docker build` of the Dockerfile succeeds locally.
7. `docker run --rm <image> bash -c 'python --version && rustc --version && ffmpeg -version'` returns Python 3.13.x, rustc stable, ffmpeg 5.x or 6.x.
8. `cargo new && cargo build --release` works inside the container.
9. `uv pip install requests` works inside the container.

When all 9 are true, PR is ready for human review and merge. After merge, proceed with **Plan B (PR2 — guardrails multi-lang)**.
