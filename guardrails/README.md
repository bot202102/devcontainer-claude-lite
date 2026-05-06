# Integration Gates — anti-"fake-work" guardrails para Claude Code

> **🤖 Si eres un AI leyendo este archivo**: este directorio contiene una plantilla
> de seguros diseñada para prevenir que Claude Code marque trabajo como "done"
> cuando en realidad los módulos solo compilan y pasan tests aislados, sin estar
> wireados al binario productivo. Ver [HOW_AI_SHOULD_APPLY_THIS.md](#how-ai-should-apply-this-section-for-ais) al final.

## El problema que resuelve

**Caso real documentado en [docs/FAKE_WORK_AUDIT.md](docs/FAKE_WORK_AUDIT.md)**: un proyecto Rust con 100+ commits, 205 tests verdes, CI OK, CLAUDE.md listando "M14 complete". En sesión live con hardware real se descubrió que **60% del feature-set era humo**:

- 11 módulos compilados con tests pasando, pero **cero callers en el binario productivo**
- Endpoints REST devolviendo placeholder `{"note": "available when connected"}`
- Security: `LICENSE_PUBLIC_KEY = [0u8; 32]` + signature verification SKIPPED en release
- Memoria del usuario decía "complete" basado en self-report de Claude, no evidencia

**Causa raíz**: Claude optimizaba por métrica barata (`cargo test` verde) sin verificar que el binario realmente usara los módulos. Tests instanciaban módulos en aislamiento (`tests/m14_integration.rs` con `ProximityAdapter::new` directo, bypassing el engine principal).

## El invariante universal

> **Todo símbolo público nuevo DEBE tener ≥1 call-site alcanzable desde el entry-point de producción antes de marcarse "done".**

Agnóstico al lenguaje. Cambia el mecanismo de verificación por lenguaje (Rust usa `cargo tree`, Python usa `ast.parse`, Node usa `tsc --listFiles`, etc.) pero el invariante es el mismo.

## Arquitectura defensiva (4 capas)

```
┌────────────────────────────────────────────────────────┐
│ Capa 1 — Context                                       │
│ SessionStart hook imprime "GHOSTS: [módulos huérfanos]"│
│ → Claude ve al arrancar qué NO está wireado           │
├────────────────────────────────────────────────────────┤
│ Capa 2 — Warning inmediato                             │
│ PostToolUse hook alerta cuando Claude crea pub fn new()│
│ sin wirearlo                                           │
├────────────────────────────────────────────────────────┤
│ Capa 3 — Hard gate                                     │
│ Stop hook BLOQUEA fin de turno (exit 2) si hay ghosts │
│ nuevos vs baseline                                     │
└────────────────────────────────────────────────────────┘
                         +
┌────────────────────────────────────────────────────────┐
│ Capa 0a (soft) — CLAUDE.md con Definition of Done      │
│ Norma declarativa. Inútil sola; indispensable          │
│ combinada con los hooks mecánicos arriba               │
├────────────────────────────────────────────────────────┤
│ Capa 0b (declarativa con evidencia) — skill verify-done│
│ Claude la invoca ANTES de afirmar "done". Corre los 6  │
│ checks del DoD y devuelve evidencia real (cargo tree,  │
│ grep, curl, log trace). No bloquea — cierra la brecha  │
│ entre "norma" (Capa 0a) y "hook mecánico" (Capa 3).   │
│ Ver skills/verify-done.md.                             │
└────────────────────────────────────────────────────────┘
```

Cobertura aproximada:
- Solo CLAUDE.md (Capa 0a): **~40%** (Claude puede driftar)
- + skill verify-done (Capa 0b): **~70%** (self-check con evidencia antes del Stop)
- + Capa 3 (Stop gate): **~90%** (cinturón mecánico captura el resto)
- + Capas 1+2: **~95%** (defensa en profundidad completa)

## Instalación — 4 pasos en proyecto nuevo

```bash
# 1. Copia guardrails/ a tu proyecto (o usa este repo como template)
cp -r /ruta/a/este/repo/guardrails/.claude /ruta/a/tu-proyecto/
cp /ruta/a/este/repo/guardrails/docs/DEFINITION_OF_DONE.md /ruta/a/tu-proyecto/guardrails-docs.md

# 2. Configura el lenguaje (2 líneas)
cd /ruta/a/tu-proyecto
cp .claude/hooks/project.conf.example .claude/hooks/project.conf
$EDITOR .claude/hooks/project.conf   # editar LANG y ENTRY_POINTS

# 3. Inicializa baseline (captura ghosts heredados, no los bloquea)
bash .claude/hooks/lang/$LANG.sh > .claude/ghost-baseline.txt
git add .claude/ghost-baseline.txt
git commit -m "chore: claude-code integration gate baseline"

# 4. Pega Definition of Done en CLAUDE.md (raíz del proyecto)
cat guardrails-docs.md >> CLAUDE.md  # o copia el bloque manualmente
```

O ejecuta el one-liner:

```bash
bash guardrails/install.sh /ruta/a/tu-proyecto rust   # o python, node, astro, nextjs, go, java
```

Ver [install.sh](install.sh) para detalle.

## Anatomía del paquete

```
guardrails/
├── README.md                    # Este archivo — overview + instalación
├── install.sh                   # Instalador one-shot
├── docs/
│   ├── FAKE_WORK_AUDIT.md       # Caso real que motivó este template
│   ├── DEFINITION_OF_DONE.md    # Bloque para pegar en CLAUDE.md
│   └── LANG_MATRIX.md           # Cómo funciona el checker por lenguaje
├── skills/
│   ├── verify-done.md           # Capa 0b — done-claim gate (self-check con evidencia)
│   ├── verify-contract.md       # cross-layer schema drift
│   ├── verify-storage.md        # storage write/read continuity
│   ├── verify-identity.md       # ID stability
│   ├── verify-honest-failure.md # observable error signals
│   └── surfacing-fakework.md   # inflight discovery — file immediately, keep moving
└── .claude/
    ├── settings.json            # Hooks registration (merge con el tuyo)
    └── hooks/
        ├── project.conf.example # Config — 2 campos: LANG + ENTRY_POINTS
        ├── ghost-report.sh      # SessionStart — imprime ghosts al arrancar
        ├── new-symbol-guard.sh  # PostToolUse — warning inmediato
        ├── integration-gate.sh  # Stop — hard gate (exit 2 si ghost nuevo)
        └── lang/                # Checker por lenguaje
            ├── rust.sh
            ├── python.sh
            ├── node.sh
            ├── astro.sh          # Astro file-based routing
            ├── nextjs.sh         # Next.js App Router (src/app/**)
            ├── go.sh
            ├── java.sh
            └── kotlin-android.sh # Android Kotlin (Koin DI + AndroidManifest)
```

## Lenguajes soportados

| Lang | Mecanismo del checker | Dependencias |
|---|---|---|
| **Rust** | `rg 'pub (struct\|fn new)' src/` → grep en `$ENTRY_POINTS`. Opcional `cargo tree --edges=normal` | `ripgrep`, `cargo` |
| **Python** | `python -m ast` extrae `def`/`class` públicas (sin `_`). Grep imports desde entry-point | `python3` |
| **Node/TS** | `tsc --listFiles` + análisis de `export` (via `grep` o `ts-morph`). Verifica import-graph desde `main` de `package.json` | `tsc` (opcional) |
| **Astro** | Variante de Node/TS para file-based routing: auto-descubre `src/pages/**` + `src/middleware.ts` + `astro.config.*` como entry-points múltiples. Excluye `pages/` de los definidores (pages son consumers). Sin `ENTRY_POINTS` requerido | `grep`, `awk`, `tr` |
| **Go** | `go list -deps ./cmd/app` → paquetes alcanzables. Diff vs paquetes con símbolos exportados nuevos | `go` |
| **Java** | `grep "import .*NewClass"` sobre `src/main/java/` + heurística de reachability | `ripgrep` |
| **Kotlin-Android** | Especialización Android de Kotlin. Scan `app/src/main/java/**/*.kt` para top-level `class`/`object`/`interface`/`enum class`/`sealed class`/`data class` + `fun` (rechaza `private`/`internal`/`protected`). Reachability sources: ENTRY_POINTS multi-archivo (MainActivity + Application class + NavGraph composable) + `AndroidManifest.xml` + auto-discovery de archivos con Koin DSL `module {`. Fallback: grep recursivo en `SCAN_ROOT`. **Requiere Android conventions** — para Kotlin server-side / KMP usa el checker `java` (que también scanea `.kt`). | `grep`, `awk`, `find` |

Ver [docs/LANG_MATRIX.md](docs/LANG_MATRIX.md) para detalle de cada uno.

### Cuándo usar `astro` vs `node`

- **`astro`**: el proyecto tiene `src/pages/` con routing file-based (Astro, SvelteKit-style, Next.js App Router con `app/`). No hay un único `"main"` en `package.json` que alcance todo el código productivo.
- **`node`**: el proyecto tiene un entry-point único (CLI, Express server con `src/index.ts`, librería publicada en npm). El campo `"main"` del `package.json` es el punto de partida real.

### Cuándo usar `kotlin-android` vs `java`

- **`kotlin-android`**: app Android nativa con `AndroidManifest.xml`, módulos DI tipo Koin (`module {...}` DSL), entry-points múltiples (MainActivity + Application class + NavGraph composable). Detecta @Composable orphans + ViewModel/UseCase/Repository sin registración Koin + clases declaradas pero no usadas en producción.
  - Validado contra Drivox CRM (~604 archivos `.kt`, 48 ghosts heredados, 7.5s baseline run).
- **`java`**: backend Java o Kotlin server-side (Spring/Ktor/Micronaut) con un único `public static void main`. El checker `java` scanea ambos `.java` y `.kt` con la misma heurística de visibilidad — pero la noción de "Public class sin caller" es la única reachability check (no Koin, no manifest).
- **Ninguno todavía cubre**: Kotlin Multiplatform (KMP) con múltiples targets, ni Compose Multiplatform desktop. Para esos casos crea un checker derivado.

## Qué NO hace este template

- **No reemplaza CI** — los hooks son dev-time, no CI/CD. El runner de CI debe ejecutar el mismo `.claude/hooks/integration-gate.sh` como step.
- **No garantiza corrección lógica** — solo detecta "código existe pero nadie lo llama". Un módulo MAL wireado (con bugs) pasa el gate.
- **No sustituye tests E2E** — los detecta como ausentes si no están, pero su presencia no implica que cubran la feature.
- **No previene bypass intencional** — un humano o Claude puede agregar el símbolo al `ghost-baseline.txt` ignorándolo. El baseline tiene que versionarse + reviewarse en PR.

## How AI should apply this (section for AIs)

**Si estás leyendo este repo como agente de Claude Code para ayudar a un humano a setear un proyecto nuevo:**

### WHEN
- Proyecto nuevo que será usado con Claude Code en modo asincrónico o con múltiples sesiones
- Proyecto existente que ya mostró síntomas de "fake-work": tests verdes pero binario no usa módulos
- Cualquier proyecto con `skipDangerousModePermissionPrompt: true` en `.claude/settings.json`

### HOW
1. Lee [docs/FAKE_WORK_AUDIT.md](docs/FAKE_WORK_AUDIT.md) para entender el patrón
2. Detecta el lenguaje del proyecto target:
   - `Cargo.toml` → rust
   - `pyproject.toml` / `setup.py` / `requirements.txt` → python
   - `package.json` con `astro` en dependencies / `astro.config.{mjs,ts,js}` presente → astro
   - `package.json` con `next` en dependencies / `next.config.{js,mjs,ts,cjs}` presente → nextjs
   - `package.json` sin Astro ni Next → node
   - `go.mod` → go
   - `app/build.gradle.kts` con `com.android.application` plugin / `app/src/main/AndroidManifest.xml` presente → kotlin-android
   - `pom.xml` / `build.gradle` (server-side, no Android) → java
3. Identifica el entry-point productivo (NO tests, NO scripts internos):
   - Rust: `crates/*/src/main.rs`, `src/main.rs`, `src/bin/*.rs`
   - Python: script con `if __name__ == "__main__"`, `__main__.py`, campo `scripts` en `pyproject.toml`
   - Node: campo `"main"` / `"bin"` en `package.json`, archivo de `"start"` script
   - Go: `cmd/<app>/main.go`
   - Java: clase con método `public static void main`
   - Kotlin-Android: `app/src/main/java/.../MainActivity.kt` + `*Application.kt` (Application class) + `*App.kt` (top-level Compose graph composable, si existe)
4. Ejecuta `bash guardrails/install.sh <target-project> <lang>`
5. Pega el contenido de [docs/DEFINITION_OF_DONE.md](docs/DEFINITION_OF_DONE.md) al final del `CLAUDE.md` del proyecto
6. Reporta al humano: "Integration gates instalados. Baseline capturado: N símbolos heredados. Ghost-check activo."

### WHERE
Los archivos finales viven en el proyecto target:
- `<project>/.claude/settings.json` — hooks registrados
- `<project>/.claude/hooks/*.sh` — scripts ejecutables
- `<project>/.claude/hooks/project.conf` — config LANG + ENTRY_POINTS
- `<project>/.claude/ghost-baseline.txt` — commited (importante para PR review)
- `<project>/.claude/skills/verify-done.md` — skill de self-check con evidencia (Capa 0b)
- `<project>/CLAUDE.md` — sección Definition of Done pegada al final

### WHAT NOT TO DO
- No modificar `integration-gate.sh` para exit 0 siempre. El `exit 2` es el punto del hook.
- No añadir al baseline un símbolo nuevo solo porque "es urgente". El baseline es para ghosts HEREDADOS al momento de instalación. Símbolos nuevos DEBEN ir al call-graph.
- No comentar el hook Stop en `settings.json`. Si bloquea, es síntoma, no ruido.

## Documentos relacionados

- [docs/FAKE_WORK_AUDIT.md](docs/FAKE_WORK_AUDIT.md) — Caso real que motivó este template (evidencia, métricas, anti-patterns)
- [docs/DEFINITION_OF_DONE.md](docs/DEFINITION_OF_DONE.md) — Bloque listo para pegar en `CLAUDE.md`
- [docs/LANG_MATRIX.md](docs/LANG_MATRIX.md) — Detalle de cada checker por lenguaje
- [skills/verify-done.md](skills/verify-done.md) — Capa 0b: done-claim gate (self-check declarativo con evidencia real)
- [skills/verify-contract.md](skills/verify-contract.md) — cross-layer schema drift
- [skills/verify-storage.md](skills/verify-storage.md) — storage write/read continuity
- [skills/verify-identity.md](skills/verify-identity.md) — ID stability
- [skills/verify-honest-failure.md](skills/verify-honest-failure.md) — observable error signals
- [skills/surfacing-fakework.md](skills/surfacing-fakework.md) — inflight discovery: file the issue, keep moving
- [install.sh](install.sh) — Instalador universal
- Claude Code hooks reference: https://docs.claude.com/en/docs/claude-code/hooks
- Claude Code settings reference: https://docs.claude.com/en/docs/claude-code/settings
- Claude Code skills reference: https://docs.claude.com/en/docs/claude-code/skills

## Licencia

Mismo del repo parent ([devcontainer-claude-lite](../README.md)).
