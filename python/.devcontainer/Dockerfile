FROM python:3.12-slim

ARG TZ
ENV TZ="$TZ"

# Essential system tools + Chromium + Playwright deps
# Build essentials: native pip packages (Pillow, cryptography, psycopg2, etc.)
# Chromium: full browser for Chrome DevTools MCP (browser automation, screenshots, accessibility snapshots)
# OPTIONAL (uncomment): postgresql-client, default-mysql-client, redis-tools, netcat-traditional
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
  sqlite3 \
  build-essential \
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

# Node.js 22 (Claude Code requires modern Node — Debian apt ships Node 18 EOL)
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
USER $USERNAME

# uv (fast Python package installer — pip can't resolve complex dep graphs)
RUN sudo pip install --no-cache-dir uv

# Python: no virtualenv needed in container, install direct
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV UV_SYSTEM_PYTHON=1
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/dev/.local/bin

# Shell
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano
ENV LANG=C.UTF-8

# Chromium: skip Playwright download, use system binary
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium

# Minimal zsh (no powerlevel10k, no oh-my-zsh)
RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> ~/.zshrc && \
  echo 'export HISTSIZE=5000' >> ~/.zshrc && \
  echo 'export SAVEHIST=5000' >> ~/.zshrc && \
  echo 'setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY INC_APPEND_HISTORY' >> ~/.zshrc && \
  echo 'autoload -Uz compinit && compinit' >> ~/.zshrc && \
  echo 'PROMPT="%F{green}%~%f %# "' >> ~/.zshrc

# NOTE: Dev Containers CLI overrides the build context when generating
# Dockerfile-with-features, so COPY referencing project files will fail
# with "no such file or directory" for the app service.
# Install deps via postCreateCommand in devcontainer.json instead.
# Worker services (built by Docker Compose without features) CAN use COPY,
# but the simplest approach is a startup pip install in the worker command.
# See docker-compose.yml worker example for details.

# Claude Code (needs npm)
ARG CLAUDE_CODE_VERSION=latest
RUN sudo npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
