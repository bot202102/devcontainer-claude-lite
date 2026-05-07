FROM python:3.13-slim

ARG TZ
ENV TZ="$TZ"

# Essential system tools + native build deps + Chromium + Playwright deps.
# Build essentials: native compilation for crates / wheels (cpal, ALSA, Pillow, ring, etc.)
# Chromium: full browser for Chrome DevTools MCP (browser automation, screenshots).
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

# OPTIONAL: audio processing libs (ffmpeg, libsndfile1, libsox-fmt-all).
# Adds ~85 MB to the image. Uncomment the RUN block below if your project
# uses pydub / soundfile / symphonia / sox. The first consumer
# (audio-a-texto) needs them; generic Python+Rust projects don't.
#
# RUN apt-get update && apt-get install -y --no-install-recommends \
#   ffmpeg \
#   libsndfile1 \
#   libsox-fmt-all \
#   && apt-get clean && rm -rf /var/lib/apt/lists/*

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
