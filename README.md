# devcontainer-claude-lite

Templates de devcontainer optimizados para vibe coding con Claude Code. Fork ligero del [devcontainer oficial de Anthropic](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

## Principio

Claude escribe todo el codigo. ESLint, Prettier y formatOnSave son CPU desperdiciado en background. Quality gates corren **solo al commit** via git hooks.

## Stacks disponibles

| Stack | Carpeta | Imagen base | Incluye |
|---|---|---|---|
| Node.js | `node/` | `node:22` | npm, pnpm (corepack), Node 22, Chromium (MCP) |
| Python | `python/` | `python:3.12-slim` | pip, Python 3.12, sqlite3, Node 22 (para Claude Code), Chromium (MCP) |

## Que tienen todos en comun

- Zsh minimo (sin powerlevel10k, sin oh-my-zsh)
- Historial persistente entre reinicios
- Docker CLI via socket del host
- Claude Code instalado globalmente
- Chromium completo para [Chrome DevTools MCP](https://github.com/anthropics/claude-code/blob/main/docs/mcp.md) (screenshots, snapshots, browser automation)
- Sin ESLint/Prettier/GitLens en background
- `setup-hooks.sh` para configurar quality gates solo en el commit (detecta npm/pnpm/bun)
- `docker-compose.yml` con servicios opcionales (PostgreSQL, Redis, MySQL, MongoDB, Jaeger)
- `postCreateCommand` auto-instala dependencias (detecta pnpm/npm/pip)
- `postStartCommand` aplica fixes de Docker Desktop (`.gitconfig` como directorio, `safe.directory`)
- File watcher excludes para reducir CPU del IDE
- Healthcheck de red en el servicio `app` (detecta perdida silenciosa de conectividad)
- Puertos parametrizables via env vars (evita conflictos entre proyectos)
- `build-essential` incluido (compilacion de paquetes nativos: sharp, Pillow, bcrypt, etc.)

## Python: deps baked into image

El template Python instala `requirements.txt` **en el Dockerfile** (no solo en `postCreateCommand`). Esto garantiza que TODOS los servicios de docker-compose (app, workers, schedulers, etc.) tengan las dependencias Python disponibles.

`postCreateCommand` sigue corriendo `pip install` como fallback para actualizar deps sin rebuild.

```
Build context = ".." (workspace root)
  -> Dockerfile COPY requirements.txt (si existe)
  -> pip install en la imagen
  -> Todos los servicios comparten la misma imagen con deps
```

## Que se elimino vs el original de Anthropic

| Aspecto | Anthropic original | Esta version |
|---|---|---|
| Shell theme | powerlevel10k | Prompt minimo |
| Extensiones VS Code | ESLint, Prettier, GitLens | Solo claude-code |
| formatOnSave | Activo | Eliminado |
| Paquetes sistema | vim, man-db, fzf, unzip, gnupg2, git-delta | Solo lo esencial + build-essential |
| NODE_OPTIONS | 4 GB | 2 GB |
| Docker | No disponible | Docker CLI via socket |
| Quality gates | En background (tiempo real) | Solo en commit (git hooks) |
| Browser | No incluido | Chromium completo (Chrome DevTools MCP) |
| Servicios | No incluidos | docker-compose.yml modular |

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
bash .devcontainer/setup-hooks.sh          # Node: detecta npm/pnpm/bun
bash .devcontainer/setup-hooks.sh          # Python: ruff only (rapido)
bash .devcontainer/setup-hooks.sh full     # Python: ruff + file checks + bandit
```

Esto instala git hooks que corren linting/formatting **solo sobre archivos staged** en el momento del commit. Cero procesos en background.

- **Node**: husky + lint-staged + eslint + prettier (auto-detecta npm/pnpm/bun)
- **Python minimal**: pre-commit + ruff (lint + format)
- **Python full**: pre-commit + ruff + pre-commit-hooks + bandit (security)

### 3. Agregar servicios (opcional)

El `docker-compose.yml` incluido trae servicios comunes comentados. Descomenta lo que necesites:

```yaml
# En .devcontainer/docker-compose.yml, descomenta:
postgres:    # PostgreSQL 16
redis:       # Redis 7
mysql:       # MySQL 8 (alternativa a PostgreSQL)
mongo:       # MongoDB 7
jaeger:      # OpenTelemetry traces
worker:      # Worker example (Python: celery/taskiq/etc.)
```

#### Evitar conflictos de puertos

Si corres multiples devcontainers o proyectos Docker simultaneamente, los puertos por defecto (5432, 6379, etc.) pueden colisionar. Esto causa una falla silenciosa: el contenedor inicia sin redes, pierde internet, y Claude Code no puede conectar a la API de Anthropic (`EAI_AGAIN`).

Para evitarlo, crea un `.env` junto al `docker-compose.yml` con puertos unicos por proyecto:

```env
# .devcontainer/.env
POSTGRES_PORT=31432
REDIS_PORT=31379
MYSQL_PORT=31306
MONGO_PORT=31017
```

**Modo standalone** (sin devcontainer integration):

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

**Modo integrado** (devcontainer levanta todo junto): en `devcontainer.json`, descomenta las lineas de `dockerComposeFile`, `service`, y `shutdownAction`.

### 4. DB clients opcionales

En el `Dockerfile`, descomenta los clientes que necesites para debug directo desde el container:

```dockerfile
# postgresql-client \
# default-mysql-client \
# redis-tools \
```

### 5. Agregar extensiones de lenguaje

Solo extensiones ligeras de soporte de lenguaje (sin linting en background):

```jsonc
"extensions": [
  "anthropic.claude-code",
  "Prisma.prisma",
  "bradlc.vscode-tailwindcss"
]
```

### 6. Chrome DevTools MCP

El container incluye Chromium completo. Para usarlo con Claude Code, agrega a tu `.mcp.json`:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--headless=true",
        "--isolated=true",
        "--executablePath=/usr/bin/chromium",
        "--chromeArg=--no-sandbox",
        "--chromeArg=--disable-setuid-sandbox"
      ]
    }
  }
}
```

## Troubleshooting

### Container sin internet / Claude Code: `EAI_AGAIN`

**Causa**: conflicto de puertos con otro contenedor. Docker crea el container sin asignar redes.

**Diagnostico**:
```bash
docker inspect <container> --format '{{json .NetworkSettings.Networks}}'
# Si devuelve {} — no tiene redes asignadas
```

**Solucion**: detener el contenedor que ocupa el puerto, o usar puertos unicos (ver seccion "Evitar conflictos de puertos").

### Healthcheck `unhealthy` en servicios de terceros

Algunas imagenes Docker (Evolution API, Chatwoot, Alpine-based) no incluyen `curl`. Si un healthcheck con `curl -f` falla con "executable not found", usa alternativas:

```yaml
# wget (disponible en la mayoria de imagenes)
test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/"]

# Comando nativo del servicio
test: ["CMD-SHELL", "pg_isready -U user -d db"]
test: ["CMD", "redis-cli", "ping"]
```

### PostgreSQL: `extension "vector" is not available`

Apps modernas (Chatwoot, Supabase, RAG pipelines) requieren pgvector. Cambia la imagen:

```yaml
postgres:
  image: pgvector/pgvector:pg16  # en lugar de postgres:16-alpine
```

## Requisitos

- Docker Desktop o Docker Engine en el host
- VS Code con la extension Dev Containers
