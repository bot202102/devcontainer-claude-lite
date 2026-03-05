# devcontainer-claude-lite

Devcontainer template optimizado para Claude CLI. Fork ligero del [devcontainer oficial de Anthropic](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

## Diferencias vs el original

| Aspecto | Anthropic original | Esta versión |
|---|---|---|
| Shell theme | powerlevel10k (calcula git status en cada prompt) | Prompt mínimo `%~ %#` |
| Extensiones VS Code | ESLint, Prettier, GitLens | Solo `anthropic.claude-code` |
| formatOnSave / codeActionsOnSave | Activo | Eliminado |
| Paquetes del sistema | vim, man-db, fzf, unzip, gnupg2, git-delta | Solo lo esencial |
| NODE_OPTIONS | 4 GB | 2 GB |
| Docker | No disponible | Docker CLI via socket del host |
| Historial shell | bash history básico | zsh con SHARE_HISTORY persistente |

## Por qué importa

Claude CLI ejecuta muchos comandos bash. Cada comando dispara el prompt de zsh. Con powerlevel10k, cada prompt calcula git status, segmentos, iconos — CPU que Claude nunca ve. ESLint/GitLens corren en background consumiendo memoria analizando archivos que Claude maneja con sus propias herramientas.

## Uso

### Como template para un proyecto nuevo

Copia la carpeta `.devcontainer/` a la raíz de tu proyecto.

### Agregar servicios (DB, Redis, etc.)

Crea un `docker-compose.yml` en `.devcontainer/` y referéncialo:

```jsonc
// devcontainer.json
{
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
  // ... resto de la config
}
```

### Agregar extensiones de lenguaje

Agrega solo extensiones de soporte de lenguaje ligeras:

```jsonc
"extensions": [
  "anthropic.claude-code",
  "Prisma.prisma",           // si usas Prisma
  "bradlc.vscode-tailwindcss" // si usas Tailwind
]
```

No agregar: ESLint, Prettier, GitLens, ni nada que corra procesos en background. El linting se hace manual (`npx eslint .`) o via git hooks pre-commit.

## Requisitos

- Docker Desktop o Docker Engine en el host
- VS Code con la extensión Dev Containers
