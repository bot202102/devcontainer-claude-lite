# devcontainer-claude-lite

Templates de devcontainer optimizados para Claude CLI por stack. Fork ligero del [devcontainer oficial de Anthropic](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

## Stacks disponibles

| Stack | Carpeta | Imagen base | Incluye |
|---|---|---|---|
| Node.js | `node/` | `node:20` | npm, Node 20 |
| Python | `python/` | `python:3.12-slim` | pip, Python 3.12, Node (para Claude Code) |

## Que tienen todos en comun

- Zsh minimo (sin powerlevel10k, sin oh-my-zsh)
- Historial persistente entre reinicios
- Docker CLI via socket del host
- Claude Code instalado globalmente
- Sin ESLint/Prettier/GitLens en background
- `setup-hooks.sh` para configurar quality gates solo en el commit

## Que se elimino vs el original de Anthropic

| Aspecto | Anthropic original | Esta version |
|---|---|---|
| Shell theme | powerlevel10k | Prompt minimo |
| Extensiones VS Code | ESLint, Prettier, GitLens | Solo claude-code + lenguaje |
| formatOnSave | Activo | Eliminado |
| Paquetes sistema | vim, man-db, fzf, unzip, gnupg2, git-delta | Solo lo esencial |
| NODE_OPTIONS | 4 GB | 2 GB |
| Docker | No disponible | Docker CLI via socket |
| Quality gates | En background (tiempo real) | Solo en commit (git hooks) |

## Uso

### 1. Copiar el template a tu proyecto

```bash
# Para Node.js
cp -r node/.devcontainer tu-proyecto/

# Para Python
cp -r python/.devcontainer tu-proyecto/
```

### 2. Configurar quality gates (una vez, en el proyecto)

```bash
# Dentro del devcontainer, en la raiz del proyecto:
bash .devcontainer/setup-hooks.sh
```

Esto instala git hooks que corren linting/formatting **solo sobre archivos staged** en el momento del commit. Cero procesos en background.

- **Node**: husky + lint-staged + eslint + prettier
- **Python**: pre-commit + ruff (lint + format)

### 3. Agregar servicios

Crea un `docker-compose.yml` junto al `Dockerfile` y usa Docker desde dentro del container:

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

O referencialo en `devcontainer.json`:

```jsonc
{
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
  // ...
}
```

### 4. Agregar extensiones de lenguaje

Solo extensiones ligeras de soporte de lenguaje:

```jsonc
"extensions": [
  "anthropic.claude-code",
  "Prisma.prisma",
  "bradlc.vscode-tailwindcss"
]
```

## Requisitos

- Docker Desktop o Docker Engine en el host
- VS Code con la extension Dev Containers
