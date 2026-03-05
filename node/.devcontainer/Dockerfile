FROM node:22

ARG TZ
ENV TZ="$TZ"

# Essential system tools + Playwright/Chromium dependencies
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
  # Chromium: full browser for Chrome DevTools MCP (not just libs)
  # Gives you browser automation, screenshots, accessibility snapshots
  chromium \
  # Chromium/Playwright shared dependencies
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
  ## -----------------------------------------------------------
  ## OPTIONAL: Uncomment what you need for your stack
  ## -----------------------------------------------------------
  ## DB clients (debug from inside container without external tools)
  # postgresql-client \
  # default-mysql-client \
  # redis-tools \
  ## Network debug
  # netcat-traditional \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Docker CLI (uses host's Docker via socket)
RUN install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# User setup
ARG USERNAME=node
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R $USERNAME:$USERNAME /usr/local/share && \
  groupadd -f docker && usermod -aG docker $USERNAME

# Allow node user to use sudo without password
RUN echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME \
  && chmod 0440 /etc/sudoers.d/$USERNAME

# Persist shell history
RUN mkdir /commandhistory && \
  touch /commandhistory/.zsh_history && \
  chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# pnpm via corepack - must run as root before USER switch
RUN corepack enable

USER node

# Node/npm globals
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Shell
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# Chromium: skip Playwright download, use system binary
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium

# Minimal zsh (no powerlevel10k, no oh-my-zsh)
RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> ~/.zshrc && \
  echo 'export HISTSIZE=2000' >> ~/.zshrc && \
  echo 'export SAVEHIST=2000' >> ~/.zshrc && \
  echo 'setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY INC_APPEND_HISTORY' >> ~/.zshrc && \
  echo 'autoload -Uz compinit && compinit' >> ~/.zshrc && \
  echo 'PROMPT="%F{blue}%~%f %# "' >> ~/.zshrc

# Claude Code
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
