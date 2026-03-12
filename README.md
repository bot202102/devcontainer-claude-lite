# devcontainer-claude-lite

Templates de devcontainer optimizados para vibe coding con Claude Code. Fork ligero del [devcontainer oficial de Anthropic](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

## Principio

Claude escribe todo el codigo. ESLint, Prettier y formatOnSave son CPU desperdiciado en background. Quality gates corren **solo al commit** via git hooks.

## Stacks disponibles

| Stack | Carpeta | Imagen base | Incluye |
|---|---|---|---|
| Node.js | `node/` | `node:22-slim` | pnpm (corepack), Node 22, Chromium (MCP) |
| Python | `python/` | `python:3.12-slim` | uv, Python 3.12, sqlite3, Node 22 (para Claude Code), Chromium (MCP) |

## Que tienen todos en comun

- Zsh minimo (sin powerlevel10k, sin oh-my-zsh)
- Historial persistente entre reinicios
- Docker CLI via socket del host
- Claude Code instalado globalmente
- Chromium completo para [Chrome DevTools MCP](https://github.com/anthropics/claude-code/blob/main/docs/mcp.md) (screenshots, snapshots, browser automation)
- Sin ESLint/Prettier/GitLens en background
- `setup-hooks.sh` para configurar quality gates solo en el commit (detecta npm/pnpm/bun)
- `docker-compose.yml` con servicios opcionales (PostgreSQL, Redis, MySQL, MongoDB, Qdrant, Minio, Jaeger)
- `postCreateCommand` auto-instala dependencias (detecta pnpm/npm/pip)
- `initializeCommand` limpia VS Code Server viejo de la VM Docker Desktop (previene "No space left on device")
- `postStartCommand` aplica fixes de Docker Desktop (`.gitconfig` como directorio, `safe.directory`)
- `userEnvProbe: "none"` para evitar inyeccion de PATH del host
- PATH hardcodeado en Dockerfile (previene rotura al construir desde WSL)
- File watcher excludes para reducir CPU del IDE
- Healthcheck de red en el servicio `app` (detecta perdida silenciosa de conectividad)
- Puertos parametrizables via env vars (evita conflictos entre proyectos)
- `build-essential` incluido (compilacion de paquetes nativos: sharp, Pillow, bcrypt, etc.)

## Python: uv en lugar de pip

El template usa [uv](https://docs.astral.sh/uv/) en lugar de pip. pip falla con `resolution-too-deep` en proyectos con grafos de dependencias complejos (LangChain, etc.). uv resuelve estos grafos en segundos.

Dev Containers CLI overrides the build context when generating Dockerfile-with-features, so `COPY` referencing project files fails with "no such file or directory". Python deps se instalan via `postCreateCommand` en el servicio `app`.

Para **worker services** (que no reciben `postCreateCommand`), el docker-compose.yml incluye un ejemplo que instala deps al inicio via `bash -c "uv pip install ... && ..."`. Es ligeramente mas lento al arrancar pero evita la complejidad de Dockerfiles separados.

```
postCreateCommand: uv pip install -r requirements.txt (app service)
worker command: bash -c "uv pip install ... && celery ..." (worker services)
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
postgres:    # PostgreSQL 17
redis:       # Redis 7
mysql:       # MySQL 8 (alternativa a PostgreSQL)
mongo:       # MongoDB 7
qdrant:      # Qdrant vector search (AI/RAG)
minio:       # Minio S3-compatible storage
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
QDRANT_PORT=31333
MINIO_PORT=31900
MINIO_CONSOLE_PORT=31901
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

### Build falla con `Syntax error - can't find = in "Files/Git/mingw64/bin"` (WSL)

**Causa**: VS Code Dev Containers CLI inyecta el PATH del host WSL (que incluye rutas Windows con espacios como `/mnt/c/Program Files/...`) al generar el Dockerfile-with-features interno. Si el Dockerfile usa `ENV PATH=$PATH:...`, el CLI expande `$PATH` con la ruta completa del host y Docker no puede parsear los espacios.

**Solucion**: El template ya tiene PATH hardcodeado en los Dockerfiles. Si usas una version anterior, reemplaza:
```dockerfile
# MAL — el CLI expande $PATH con rutas Windows
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# BIEN — inmune a la inyeccion
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/share/npm-global/bin
```

Ademas, `devcontainer.json` incluye `"userEnvProbe": "none"` para minimizar la contaminacion del entorno del host.

**Nota**: `userEnvProbe: "none"` solo afecta el probe del lado del container. El probe del host (donde ocurre la inyeccion) pasa antes de leer `devcontainer.json`. Por eso el PATH hardcodeado es la solucion real.

### Build falla con `unknown instruction: postgresql-client` o paquete como instruccion Docker

**Causa**: Los comentarios inline dentro de lineas con continuacion `\` en un `RUN` de Docker rompen el procesamiento del CLI de Dev Containers. Al generar el Dockerfile-with-features, el CLI colapsa las lineas y los `#` comentan el resto, causando que el paquete siguiente aparezca como una instruccion Docker desconocida.

**Solucion**: No poner comentarios inline dentro de bloques `RUN` con `\`. Mover los comentarios arriba del `RUN`:
```dockerfile
# BIEN — comentarios antes del RUN
# Build essentials: native npm packages (node-gyp, sharp, bcrypt)
RUN apt-get install -y \
  build-essential \
  python3 \
  && apt-get clean

# MAL — comentarios inline rompen el Dockerfile-with-features
RUN apt-get install -y \
  # Build essentials
  build-essential \
  python3 \
  && apt-get clean
```

### Rebuild falla con "No space left on device" (Docker Desktop / Windows)

**Causa**: Docker Desktop usa una VM WSL (`docker-desktop`) con un root filesystem de solo 136MB. VS Code Dev Containers instala un binario `node` de ~62MB ahi como paso intermedio antes de copiarlo al contenedor. Las instalaciones anteriores se acumulan y llenan el disco.

**Diagnostico**:
```bash
# Verificar espacio en la VM
powershell.exe -NoProfile -Command "wsl -d docker-desktop -- df -h /"
# Si muestra 100% — este es el problema
```

**Limitacion**: VS Code intenta instalar el VS Code Server en la VM WSL **antes** de ejecutar `initializeCommand`. Por eso el `initializeCommand` del template solo limpia residuos del intento anterior — ayuda en el **segundo** rebuild, no en el primero.

**Solucion (primera vez)** — ejecutar manualmente antes del rebuild:
```bash
wsl -d docker-desktop -- rm -rf /root/.vscode-remote-containers /root/.vscode-server
```

**Prevencion automatica**: El template incluye `initializeCommand` que ejecuta `initialize.sh` — un script cross-platform que detecta si esta en Windows/WSL y limpia residuos antes de cada build. Si estas usando una version anterior del template, agrega a tu `devcontainer.json`:

```jsonc
"initializeCommand": "bash .devcontainer/initialize.sh"
```

**Limpieza adicional** (si el disco de datos de Docker tambien esta lleno):
```bash
docker builder prune -a -f    # Build cache (puede ser decenas de GB)
docker system prune --volumes  # Imagenes/volumenes huerfanos
docker system df               # Verificar espacio recuperado
```

### Container sin internet / Claude Code: `EAI_AGAIN`

**Causa**: conflicto de puertos con otro contenedor. Docker crea el container sin asignar redes.

**Diagnostico**:
```bash
docker inspect <container> --format '{{json .NetworkSettings.Networks}}'
# Si devuelve {} — no tiene redes asignadas
```

**Solucion**: detener el contenedor que ocupa el puerto, o usar puertos unicos (ver seccion "Evitar conflictos de puertos").

### Healthcheck `unhealthy` en servicios de terceros

Algunas imagenes Docker (Qdrant, Evolution API, Chatwoot, Alpine-based) no incluyen `curl`. Si un healthcheck con `curl -f` falla con "executable not found", usa alternativas:

```yaml
# bash /dev/tcp (funciona en cualquier imagen con bash, sin curl ni wget)
# Ideal para imagenes minimales como qdrant/qdrant
test: ["CMD-SHELL", "timeout 2 bash -c 'echo > /dev/tcp/localhost/6333' || exit 1"]

# wget (disponible en la mayoria de imagenes)
test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/"]

# Comando nativo del servicio
test: ["CMD-SHELL", "pg_isready -U user -d db"]
test: ["CMD", "redis-cli", "ping"]
```

### `npm notice` messages when using pnpm

**Causa**: Usar `npx` en lugar de `pnpm exec` en scripts de post-start o comandos invoca npm internamente, mostrando mensajes `npm notice` confusos.

**Solucion**: En proyectos con pnpm, usar siempre `pnpm exec` en lugar de `npx`:
```bash
# MAL — muestra npm notices
npx prisma generate

# BIEN — usa pnpm directamente
pnpm exec prisma generate
```

### PostgreSQL: `extension "vector" is not available`

Apps modernas (Chatwoot, Supabase, RAG pipelines) requieren pgvector. Cambia la imagen:

```yaml
postgres:
  image: pgvector/pgvector:pg17  # en lugar de postgres:16-alpine
```

## Requisitos

- Docker Desktop o Docker Engine en el host
- VS Code con la extension Dev Containers
