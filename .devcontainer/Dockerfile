FROM node:20

ARG TZ
ENV TZ="$TZ"

# Install essential tools only (no vim, man-db, fzf, unzip, gnupg2)
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
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (not the daemon — uses host's Docker via socket)
RUN install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Allow node user to use docker without sudo
RUN groupadd -f docker && usermod -aG docker $USERNAME

# Persist shell history
RUN mkdir /commandhistory && \
  touch /commandhistory/.zsh_history && \
  chown -R $USERNAME /commandhistory

# Set environment
ENV DEVCONTAINER=true

# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# Set up non-root user
USER node

# Global npm config
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Shell defaults
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# Minimal zsh: persistent history + autocompletion + simple prompt
# No powerlevel10k, no oh-my-zsh, no fzf — saves CPU on every prompt
RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> ~/.zshrc && \
  echo 'export HISTSIZE=2000' >> ~/.zshrc && \
  echo 'export SAVEHIST=2000' >> ~/.zshrc && \
  echo 'setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY INC_APPEND_HISTORY' >> ~/.zshrc && \
  echo 'autoload -Uz compinit && compinit' >> ~/.zshrc && \
  echo 'PROMPT="%F{blue}%~%f %# "' >> ~/.zshrc

# Install Claude Code globally
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
