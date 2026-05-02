# Matrix de checkers por lenguaje

Cada checker en `.claude/hooks/lang/<lang>.sh` implementa una heurística para detectar
"símbolos públicos nuevos sin call-site alcanzable desde el entry-point productivo".

El invariante es agnóstico. El mecanismo varía según el build system y la
filosofía de visibilidad de cada lenguaje.

Adicionalmente hay **detectores orthogonales** que atacan otras clases de fake-work:

- `sql-drift-drizzle.sh` — raw SQL que referencia tablas inexistentes en el schema de Drizzle.
- `silencer-detect.sh` — `try { await …dbCall… } catch { /* empty */ }` patrones que silencian errores críticos. Ver la sección "Silencer anti-pattern".

## Baseline format

El archivo `.claude/ghost-baseline.txt` usa el formato **`file:symbol`** (una línea por ghost aceptado). La línea de declaración del símbolo NO se incluye en la clave — solo el archivo y el nombre del símbolo.

```
src/lib/api/helpers.ts:ApiError
src/lib/db/queries/prayer-requests.ts:PrayerRequestRow
src/components/core/Sidebar.astro:NavItem
```

**Por qué symbol-based y no line-based**: un formato previo `file:line:symbol` era frágil — agregar un `import` en la línea 1 de un archivo shifteaba el número de línea de TODOS los símbolos debajo, generando N "ghosts nuevos" espúreos aunque ningún símbolo cambió realmente. El formato actual es line-independent: la identidad es (archivo, símbolo), no (archivo, línea, símbolo).

**El output al usuario** (cuando el gate bloquea o reporta ghosts clearados) SÍ incluye el line number para navegación:
```
INTEGRATION GATE BLOCK: new public symbols have no call-site reachable from src/pages/.

  src/lib/db/queries/newThing.ts:42:someNewGhost
```

**Migración automática**: si `integration-gate.sh` detecta un baseline en formato legacy (`file:line:symbol`), lo migra al nuevo formato en el próximo run — mensaje de log + baseline reescrito. Un consumidor con baseline pre-existente no necesita migrar manualmente; el proceso es idempotente y no bloquea.

## Contrato de cada checker

**Input**: variables de entorno definidas en `project.conf`:
- `ENTRY_POINTS` — paths relativos (space-separated) al entry-point productivo
- `SRC_GLOBS` — directorio raíz del scan (default: auto por lenguaje). El
  semantics depende del checker: `node.sh` lo usa como SCAN_ROOT (un único
  directorio); otros checkers pueden tratarlo como glob.
- `TEST_EXCLUDES` — patrones a excluir del scan (default: auto por lenguaje).
  **Estos son substrings LITERALES** pasados a `grep -v`, NO globs de shell.
  Usar `.stories.` en vez de `*.stories.*`. Usar `/e2e/` en vez de `**/e2e/**`.

**Output**: `stdout` — una línea por ghost, formato:
```
<archivo:lnumber>:<símbolo>
```

**Exit code**: `0` siempre (el gate decide con exit 2, no el checker).

## Rust

### Mecanismo
```bash
# 1. Extraer todas las definiciones públicas en SRC_GLOBS (fuera de tests)
rg -t rust --glob '!**/tests/**' --glob '!**/*_test.rs' \
   '^(pub )?(fn|struct|enum|trait)' -n --with-filename

# 2. Para cada símbolo público, grep en ENTRY_POINTS (typicamente `src/main.rs` o `src/bin/*.rs`)
grep -l "$symbol" "$ENTRY_POINTS"
```

### Opcional (más preciso)
```bash
# cargo tree muestra qué crates están REALMENTE linkeados al binario productivo
cargo tree -p <bin-crate> --edges=normal --prefix=depth
```
Un crate que no aparezca no está en el binario, sin importar cuántos tests tenga.

### Limitaciones
- Re-exports (`pub use`) complican el grep de call-sites — un símbolo puede ser
  llamado por el nombre de re-export, no el original
- Macros que generan código (`async_trait`, `tokio::main`) no aparecen en grep

### Archivos
- `.claude/hooks/lang/rust.sh` — checker

## Python

### Mecanismo
```bash
# 1. AST parsing para extraer funciones/clases top-level NO prefijadas con _
python3 -c "
import ast, sys
for path in sys.argv[1:]:
    tree = ast.parse(open(path).read())
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if not node.name.startswith('_'):
                print(f'{path}:{node.lineno}:{node.name}')
" src/**/*.py

# 2. Para cada símbolo, grep 'import <symbol>' o 'from <mod> import <symbol>' en ENTRY_POINTS
```

### Opcional (más preciso)
- `pydeps <entry_point>` genera call-graph real
- `importlib.util.find_spec` para verificar que el módulo esté en PYTHONPATH del entry-point

### Limitaciones
- Python no tiene `public/private` a nivel de compilador. `_` prefix es convención
- Imports dinámicos (`importlib.import_module`) son invisibles al grep estático

### Entry-point candidates
- Script con `if __name__ == "__main__":`
- `__main__.py` de un paquete
- Campo `[project.scripts]` en `pyproject.toml`
- Campo `entry_points={'console_scripts': [...]}` en `setup.py`

### Archivos
- `.claude/hooks/lang/python.sh` — checker

## Node / TypeScript

### Mecanismo
```bash
# 1. Extraer todas las exports top-level (grep heurístico, suficiente en práctica)
rg 'export (const|let|var|function|class|async function|default)' \
   --glob '!**/node_modules/**' --glob '!**/*.test.ts' --glob '!**/*.spec.ts' \
   -n --with-filename src/

# 2. Para cada export, verificar que aparezca en import-graph del entry-point
#    (campo "main" de package.json, o el binario referenciado por "bin")
grep -r "import.*\b<symbol>\b\|require\([\"']\b.*<symbol>\b\)" --include='*.ts' --include='*.js' $ENTRY_DIR
```

### Opcional (más preciso)
```bash
# tsc --listFiles muestra todos los archivos que TypeScript incluye al compilar
tsc --noEmit --listFiles | grep src/ | sort -u
```
Archivos que no aparezcan no son parte del bundle productivo.

### Con ts-morph (si disponible)
```typescript
import { Project } from "ts-morph";
const project = new Project({ tsConfigFilePath: "tsconfig.json" });
const srcFiles = project.getSourceFiles();
// Analizar exports + imports con AST
```

### Limitaciones
- Dynamic imports (`import()`) no siempre son rastreables estáticamente
- Re-exports tipo barrel (`export * from './module'`) pueden crear falsos positivos

### Self-match exclusion (regression-fix)

El scan recursivo del directorio del entry-point **debe excluir el archivo
que define el símbolo**. Cuando `find` itera sobre `ep_dir`, encuentra el
propio archivo del export — y la línea `export function foo()` contiene
trivialmente el token `foo`, por lo que `grep -qw "$symbol"` siempre
matchea. Sin la exclusión `! -path "$defining_file"`, cada símbolo
self-matchea y el gate nunca bloquea (caso real reproducido en un workspace
pnpm con Express + TypeScript donde `ENTRY_POINTS=backend/src/index.ts`
y todos los archivos viven bajo `backend/src/`).

El checker actual extrae `defining_file` parseando la línea
`file:NR:symbol` (sed strip de los dos últimos campos) y lo pasa como
`! -path` a `find`. Comparar con `nextjs.sh` que ya tenía esta exclusión
vía `is_self` en su corpus tokenizado.

### Entry-point candidates
- Campo `"main"` en `package.json`
- Campo `"bin"` en `package.json` (para CLIs)
- Campo `"start"` en `scripts`
- Archivo principal de Next.js / Express / Fastify
- Para Vite SPAs: `<app>/src/main.tsx` (referenciado desde `index.html`)

### Recipe: Vite SPA en monorepo

Caso común no cubierto por los defaults de `install.sh`: monorepo pnpm con
una app Vite (`apps/web`, `apps/dashboard`, etc.) donde no hay un único
`"main"` en raíz y el SPA monta vía `<script type="module" src="/src/main.tsx">`
desde `index.html`.

`node.sh` funciona perfectamente para este caso, pero requiere `project.conf`
custom porque la heurística de `install.sh` no detecta el path anidado. Config
de referencia (probada en `bot202102/leyia`, ~120 archivos TS/TSX, 93 ghosts
heredados al instalar):

```bash
LANG="node"

# Entry-point del SPA. dirname(ENTRY_POINTS) = apps/web/src/ es la raíz
# productiva: el checker greppea recursivamente desde ahí, lo que cubre
# todos los componentes/hooks/stores que un SPA importa transitivamente
# desde main.tsx → App.tsx → DockLayout → Panel → ...
ENTRY_POINTS="apps/web/src/main.tsx"

# Constrain el scan al frontend (sin esto, el checker se mete en scripts/,
# doc/, configs de raíz y ensucia el baseline).
SRC_GLOBS="apps/web/src"

# Substrings literales (ver §Contrato). Storybook stories y test-utils
# disparan ruido masivo si no se excluyen.
TEST_EXCLUDES=".stories. /storybook-static/ /e2e/ /src/test/ /__tests__/ playwright.config"
```

Limitación conocida: tipos exportados pero usados solo dentro de su archivo
de definición (`export interface Foo` consumido como return type por una
función exportada en el mismo file) aparecen como ghosts porque el checker
excluye el defining file del consumer scan. Aceptarlos en el baseline es
correcto — el invariante "todo export tiene call-site externo" no aplica a
tipos puramente internos.

### Archivos
- `.claude/hooks/lang/node.sh` — checker

## Astro

### Por qué un checker separado de `node`

Astro es **file-based routing**: `src/pages/**/*.astro` y `src/pages/api/**/*.ts` son
entry-points implícitos — no hay un único `src/index.ts` que el campo `"main"` de
`package.json` apunte. El checker `node.sh` pide un `ENTRY_POINTS` concreto y
grepea solo dentro de ese archivo + su dir. En Astro fallaría inmediatamente
porque un símbolo consumido desde `src/pages/api/users/[id].ts` no aparece en
ningún `ENTRY_POINTS` razonable.

`astro.sh` resuelve esto escaneando el árbol entero de `src/` + `middleware.ts` +
`astro.config.*` como corpus de referencia, excluyendo los archivos de `src/pages/`
de la lista de *definidores* (porque pages son consumidores, no módulos
compartidos).

### Mecanismo

```bash
# 1. Archivos que pueden DEFINIR símbolos compartidos (excluye pages/ y tests)
find src -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o ... \) \
    | grep -v '^src/pages/' | grep -v '\.test\.\|\.spec\.\|/__tests__/'

# 2. Extraer top-level exports por grep heurístico
#    export (const|let|var|function|async function|class|enum|interface|type)

# 3. Corpus de referencia: todos los archivos de src/ (incluye pages + .astro)
#    más middleware.ts y astro.config.{mjs,ts,js} en la raíz del proyecto.

# 4. Tokenizar el corpus en pares "token:file" (identificadores únicos por archivo)

# 5. Un símbolo es ghost si su nombre NO aparece en ningún archivo del corpus
#    distinto al suyo propio (exclusión de self-hits).
```

El paso 4 (tokenización) permite evitar un `grep -w` por-símbolo sobre cientos de
archivos. Con ~1,500 archivos TS en un proyecto Astro mediano, el checker corre
en ~2-3s — bien dentro del timeout de 60s del Stop hook.

### Entry-points auto-detectados

`astro.sh` NO requiere `ENTRY_POINTS` configurado — ignora la variable. Los roots
se auto-detectan:

- `src/pages/**/*.astro` — páginas server-rendered
- `src/pages/api/**/*.{ts,tsx,js,mjs}` — API routes
- `src/pages/**/*.{ts,tsx}` — endpoints dinámicos
- `src/middleware.ts` / `src/middleware.js` (si existen)
- `astro.config.{mjs,ts,js}` en la raíz

Si tu proyecto usa un `pages/` dir no estándar, override con `SRC_GLOBS` (apunta
al root del scan, no del entry-point específico).

### Over-approximation intencional

El checker NO hace true module-reachability (eso requeriría un parser de imports
que resuelva `@/` alias + barrel re-exports + `export * from`). En su lugar
acepta como "wired" cualquier símbolo cuyo nombre aparezca en CUALQUIER archivo
del corpus distinto al suyo — incluyendo archivos dentro de otros ghosts. Esto
produce falsos positivos (símbolos usados solo entre ghosts marcados como
wired) y falsos negativos aceptables (barrels).

La baseline mechanism absorbe ambos: el primer run captura ~N símbolos
heredados como aceptados, los commit reviewers deciden si wirear/borrar con
el tiempo, y los NEW ghosts (no-presentes-en-baseline) son los que bloquean
fin de turno.

### Limitaciones específicas

- **Barrel re-exports (`export * from './X'`)**: el símbolo `foo` definido en `X`
  NO aparece textualmente en el barrel. Si ningún consumer importa `foo` por
  nombre (solo el barrel), el checker lo flagea como ghost. Fix: tu código
  probablemente SÍ lo referencia en algún consumer (grep manual). Si realmente
  es accedido solo vía barrel indirecto, agrégalo a baseline.
- **Uso en componentes `.astro`**: los archivos `.astro` SÍ están incluidos en el
  corpus de tokenización, pero solo el frontmatter (script block) se tokeniza
  correctamente — el template puede referir componentes React con sintaxis
  JSX dentro de un bloque `{}` que tr/awk cortan en tokens también. En
  práctica funciona.
- **Rutas dinámicas (`[...slug].astro`)**: el checker las incluye — funcionan
  como cualquier otro archivo del corpus.

### Entry-point candidates

- No aplicable — auto-detectados. El campo `ENTRY_POINTS` del `project.conf`
  es informativo para los mensajes del gate; no lo usa el checker.

### Archivos

- `.claude/hooks/lang/astro.sh` — checker

## Next.js (App Router)

### Por qué un checker separado de `node` y `astro`

Next.js 13+ con App Router también es **file-based routing**, pero las
convenciones difieren de Astro:

- Los roots viven en `src/app/**` (o `app/**` sin carpeta `src/`), no en
  `src/pages/` — aunque Next.js mantiene `pages/` como soporte legacy
- Archivos-rol por convención de nombre dentro de `app/`:
  `page.{ts,tsx}`, `layout.{ts,tsx}`, `route.{ts,js}`,
  `loading.{ts,tsx}`, `error.{ts,tsx}`, `not-found.{ts,tsx}`,
  `template.{ts,tsx}`
- La configuración es `next.config.{js,mjs,ts,cjs}`, no `astro.config.*`
- Middleware va en `middleware.ts` en la raíz (o en `src/middleware.ts`)
- Observability en `instrumentation.{ts,js}` (si se usa)
- Route handlers exportan símbolos con nombres-contrato del runtime que NO
  son "llamados" por código propio: `GET`/`POST`/`PUT`/`DELETE`/`PATCH`/
  `OPTIONS`/`HEAD`, `generateMetadata`, `generateStaticParams`,
  `generateViewport`, `metadata`, `viewport`, `revalidate`, `dynamic`,
  `dynamicParams`, `runtime`, `preferredRegion`, `maxDuration`, `default`
  (el page/layout/route handler en sí)

`nextjs.sh` hereda el modelo de `astro.sh` — corpus de tokens + exclusión
self-hit — pero con estas diferencias:

1. Excluye `src/app/**` y `src/pages/**` del set de "definidores"
2. Archivos `.astro` no aplican; escanea `.ts/.tsx/.js/.jsx/.mjs/.cjs`
3. Busca archivos root-level en la raíz del proyecto Y en el padre de
   `SRC_GLOBS` (útil para monorepos donde `SRC_GLOBS=apps/web/src` y
   `next.config.js` vive en `apps/web/`)
4. Skip list incluye los nombres-contrato del runtime de Next.js

### Mecanismo

```bash
# 1. Definidores: src/**.{ts,tsx,js,jsx,mjs,cjs} fuera de app/, pages/, tests
find "$SRC_ROOT" -type f \( -name '*.ts' -o -name '*.tsx' -o ... \) \
    | grep -v "^${SRC_ROOT}/app/" \
    | grep -v "^${SRC_ROOT}/pages/" \
    | grep -vE '\.test\.|\.spec\.|__tests__|__mocks__|\.d\.ts$'

# 2. Extraer exports top-level via heurística grep/awk
#    (igual que astro.sh)

# 3. Corpus: todo $SRC_ROOT (incluye app + pages) + archivos raíz Next.js
for root_file in middleware.{ts,js} next.config.{js,mjs,ts,cjs} instrumentation.{ts,js}; do
    [ -f "$root_file" ] && echo "$root_file" >> "$CORPUS"
    [ -f "$SRC_PARENT/$root_file" ] && echo "$SRC_PARENT/$root_file" >> "$CORPUS"
done

# 4. Tokenizar + detectar ghosts con skip-list de convenciones Next
```

### Entry-points auto-detectados

`nextjs.sh` ignora `ENTRY_POINTS` del config igual que `astro.sh`. Los
roots son, en orden de prioridad:

- `$SRC_GLOBS/app/**/{page,layout,route,loading,error,not-found,template}.{ts,tsx,js,jsx}`
- `$SRC_GLOBS/pages/**` (legacy pages router, si coexiste)
- `middleware.{ts,js}` en raíz del proyecto o padre de `$SRC_GLOBS`
- `next.config.{js,mjs,ts,cjs}` en raíz o padre
- `instrumentation.{ts,js}` en raíz o padre

Si tu proyecto usa un root no estándar (p.ej. `apps/web/src` en un monorepo
Turborepo), configura `SRC_GLOBS=apps/web/src`.

### Limitaciones específicas

- **`import type` de TypeScript**: identificadores usados solo en posición
  de tipo pueden producir falsos positivos. Baseline los absorbe.
- **Path aliases (`@/components`)**: el tokenizer ve el símbolo importado
  pero no resuelve la ruta. Si alguien importa `@/lib/foo` y `foo` nunca
  aparece por nombre en otro archivo, flagea. En la práctica casi siempre
  hay un consumer con `import { foo } from '@/lib/foo'` que sí contiene
  el token.
- **React Server Components con `"use server"`**: funcionan como cualquier
  export tipo función; si son invocadas desde un client component, el
  tokenizer las detecta.
- **Route handlers solos**: un `app/api/foo/route.ts` que solo exporta
  `GET`/`POST` no define símbolos reusables — el filtro "excluir app/**"
  del set de definidores lo evita.

### Entry-point candidates

- No aplicable — auto-detectados. `ENTRY_POINTS` del `project.conf` es
  informativo.

### Archivos

- `.claude/hooks/lang/nextjs.sh` — checker


## Schema-SQL drift (Drizzle) — defense class complementaria

### Por qué un checker orthogonal al ghost checker

El ghost checker detecta **símbolos** (exports) sin call-site. No puede detectar un bug en el CONTENIDO de un string SQL. Un caso real:

```ts
// Drizzle schema declara:
export const smallGroupMembers = pgTable('group_members', { ... });

// Drizzle query (OK):
await db.select().from(smallGroupMembers);   // resuelve a 'group_members'

// Raw SQL template (ROTO):
sql`... FROM small_group_members sgm ...`    // tabla inexistente, 500 en prod
```

El TS compiler ve `sql\`...\`` como string opaco. El ghost checker ve `smallGroupMembers` como wired. Nadie atrapa el bug hasta que la query corre — y en un incidente reciente, tardó 11 días.

### Mecanismo

```bash
# 1. Extraer nombres reales de tablas desde pgTable('<name>', ...)
grep -oE "pgTable[[:space:]]*\(['\"][^'\"]+['\"]" src/**/schema/*.ts | ...

# 2. Scanear archivos con raw-SQL vehicles (sql` o .query() )
# 3. Por archivo, detectar CTEs (WITH RECURSIVE name AS …) y agregarlos al set conocido.
# 4. Extraer referencias FROM/JOIN/INTO/UPDATE <name> de cada archivo.
# 5. Filtrar: líneas con comentarios JS, funciones SQL con FROM (EXTRACT, CAST).
# 6. Diff: nombres referenciados que NO están en la unión de {tablas reales} ∪ {CTEs del archivo} ∪ {system tables} ∪ {SQL keywords} ∪ {prose comunes}.
```

### Invocación

No es un hook por defecto (es complementario al ghost checker, no sustituto). Uso manual o integrable como SessionStart adicional:

```bash
bash .claude/hooks/lang/sql-drift-drizzle.sh
# stdout: file:line:<referenced-name> por cada drift sospechoso
```

Config:
- `SCHEMA_GLOBS` — dirs con `pgTable()` declarations. Default: `src/lib/db/schema src/db/schema drizzle/schema`.
- `SRC_GLOBS` — dirs para scanear. Default: `src`.
- `SQL_DRIFT_KNOWN_TABLES` — whitelist adicional (views, extension tables, CTEs no-detectados).

### Limitaciones conocidas

- **Heurística por regex, no parser SQL**. Detecta lo obvio; tiene ~10-30% FPs típicamente (prose en comments/strings JS que contienen "from X").
- **No detecta bugs indirectos**. Si el nombre de la tabla viene de un string-builder o map (`ENTITY_TABLE_MAP[entityType]`), el string real nunca aparece literalmente en el código — el checker no puede resolverlo. Ejemplo: `FROM ${ENTITY_TABLE_MAP[entityType]}` con map que tiene un valor inválido.
- **CTEs con alias en subquery**: si se usa `SELECT * FROM (SELECT …) AS sub_query` el `sub_query` se ve como tabla. Agrégalo a `SQL_DRIFT_KNOWN_TABLES` o al alias list.
- **Interpolaciones `${var}`**: el checker NO intenta resolver JS template vars. Si dentro del template aparece `FROM ${dynamic_name}`, pasa desapercibido.

### Caso de uso típico

1. Primer run sobre un repo existente → ~N findings
2. Triage humano: cuáles son reales vs CTE/alias/prose → extender `SQL_DRIFT_KNOWN_TABLES`
3. Runs subsecuentes → el delta (findings nuevos no-esperados) es actionable

Como el ghost checker, funciona mejor con una **baseline** — pero ese patrón se deja al consumidor.

### Archivos

- `.claude/hooks/lang/sql-drift-drizzle.sh` — checker

## Silencer anti-pattern (detección orthogonal)

### Motivación — caso real

En un consumer repo, esta pieza de SSR Astro silenció un HTTP 500 por 11 días:

```ts
// dashboard/index.astro
try {
  pastorDashboardData = await getPastorDashboardData(tenantId);
} catch {
  // Fallback — client will fetch
}
```

La query debajo estaba rota (raw SQL con nombre de tabla inválido). El `catch {}` tragó el error. El cliente fetcheó el mismo endpoint roto, también obtuvo 500, y mostró empty state. 14+ usuarios trataron "dashboard vacío" como "no hay datos aún" durante 11 días. Ningún alert, ningún ticket — hasta que alguien revisó los logs del container.

### Mecanismo

`silencer-detect.sh` es un state-machine awk que escanea `.ts/.tsx/.js/.jsx/.astro`:

1. **Estado 0**: busca líneas como `try {` o `try\s*$` (con brace en línea siguiente).
2. **Estado 1** (dentro del try): busca indicadores de producción data-call:
   - `await` (genérico)
   - `.query(` (pg, knex, …)
   - `` sql` `` (drizzle template)
   - `fetch(`, `.request(`, `.send(`
   - imports desde `@/lib/db/queries`
3. Al encontrar `} catch {` (con o sin param), pasa a **Estado 2**.
4. **Estado 2** (dentro del catch): clasifica cada línea:
   - `}` solo → catch vacío. Si había DB indicator en try → emite finding.
   - Solo comentarios (`//`, `*`, `/*`, `*/`) → catch "silenciado" (mismo trato).
   - Cualquier código real (log, throw, set-state) → NO silenciado. Estado vuelve a 0.

### Output

```
src/pages/dashboard/index.astro:39:silenced-data-call
src/components/core/OfflineIndicator.tsx:33:silenced-data-call
```

Una línea por silencer detectado, apuntando al `try` donde empezó.

### Qué NO atrapa

- `catch (e) { /* ignore */ throw new Error('different'); }` — el throw lo rescata (OK, no es silenciador).
- `catch { return defaultValue; }` — código real presente. Marcado como no-silenciado. (Defensive pero no silencioso — el caller ve `defaultValue` distinto del resultado OK.)
- `try { fetch(…) }` sin `await` — async fire-and-forget. La promesa rejected puede caer en `unhandledRejection`, no en el catch. Falsa sensación de cobertura. Este checker lo flaggea igualmente porque el `fetch(` indicator hace match.

### Limitaciones

- **Graceful degrade intencional** — en frontend, `try { read-from-IndexedDB } catch { // not available }` es pragmático y válido. El checker NO distingue. Output requiere triage humano: aceptar los legítimos, arreglar los que realmente ocultan bugs.
- **Catches con `console.error`** — marcados como no-silenciados (hay código real), pero si el console.error nunca se revisa en prod, sigue siendo silencioso de facto. Sólo un sistema de alerting real resuelve esto (fuera del alcance del checker).
- **Server-side swallows sin logging** — el caso real del incidente. **Este es el objetivo primario del checker.** Si el try hace `await dbQuery()` + el catch está vacío o solo con comment, algo probablemente está mal.

### Invocación

No está cableado como hook por defecto (sería demasiado ruido en la mayoría de proyectos existentes). Uso manual o como step adicional de CI:

```bash
bash .claude/hooks/lang/silencer-detect.sh
```

Consumidores pueden integrar como SessionStart informational o Stop blocking una vez triageados los legítimos a través de un `baseline`-like list.

### Archivos

- `.claude/hooks/lang/silencer-detect.sh` — checker

## Go

### Mecanismo
```bash
# 1. Listar paquetes alcanzables desde el entry-point
go list -deps ./cmd/<app> | sort > reachable_packages.txt

# 2. Listar todos los paquetes con símbolos exportados nuevos (CamelCase)
rg '^(func|type|var|const) [A-Z]' --glob '!**/*_test.go' \
   -n --with-filename | sort > exported_symbols.txt

# 3. Diff: símbolos exportados cuyo paquete NO está en reachable
```

### Limitaciones
- Interfaces y reflection pueden ocultar dependencias
- `init()` functions se ejecutan por import — fácil de perder

### Entry-point candidates
- `cmd/<app>/main.go` (convención más común)
- `main.go` en la raíz
- Campo `main` explícito en scripts de build

### Archivos
- `.claude/hooks/lang/go.sh` — checker

## Java

### Mecanismo
```bash
# 1. Clases públicas en src/main/java/
rg 'public (class|interface|enum)' src/main/java -n

# 2. Para cada clase, grep de "import <package>.<Class>" en paquete del entry-point
# Entry-point: clase con public static void main(String[] args)
```

### Opcional
- Maven/Gradle dependency:tree
- ASM para bytecode analysis (costoso, excesivo para hook dev-time)

### Limitaciones
- Reflection y Spring DI ocultan dependencias (pero esas dependencias se resuelven en runtime, no compile — si la clase es necesaria pero no aparece en imports explícitos, el gate da falso positivo)
- Classes sin modifier explícito son package-private; pueden ser usadas sin `import`

### Entry-point candidates
- Clase con `public static void main(String[] args)`
- Campo `mainClass` en `pom.xml` / `build.gradle`

### Archivos
- `.claude/hooks/lang/java.sh` — checker

## Kotlin-Android

### Por qué un checker separado de `java`

Aunque `java.sh` puede escanear `.kt` files (la heurística `public class` también
matchea Kotlin), Android viola tres asunciones del modelo Java estándar:

1. **Visibilidad por defecto invertida**: Kotlin classes son public por default
   (sin keyword); el grep `public (class|interface|enum)` de `java.sh` se pierde
   90% de las clases. Hay que invertir la lógica: aceptar todas las clases y
   rechazar las explícitamente `private`/`internal`/`protected`.
2. **Multi-entry-point**: Una app Android no tiene un solo `main()`. Tiene
   `MainActivity` (manifest-declared), `Application` class (manifest-declared),
   `BroadcastReceiver`/`Service`/`Provider` (manifest-declared), y un grafo de
   navegación Compose top-level (típicamente `MyApp.kt` con un `NavHost`). El
   `java.sh` con un `ENTRY_POINTS` único no captura todo este wiring.
3. **DI por convención (Koin)**: clases que el grafo nunca importa
   directamente — `viewModel { FooViewModel() }`, `single { FooRepository() }` —
   están wireadas vía DSL en archivos bajo `core/di/`. El checker tiene que
   tratar cualquier `.kt` con patrón `module {` como reachability source.

`kotlin-android.sh` resuelve los tres puntos: scan column-0 con visibilidad
invertida, ENTRY_POINTS multi-archivo, auto-discovery de Koin DSL files.

### Mecanismo

```bash
# 1. Definidores: app/src/main/java/**/*.kt, excluyendo test/androidTest/build
find "$SCAN_ROOT" -type f -name '*.kt' \
    | grep -vE '(/src/test/|/src/androidTest/|/build/|Test\.kt$|Tests\.kt$|Spec\.kt$|TestKoin\.kt$)'

# 2. Extraer top-level public symbols (column 0, no leading whitespace).
#    Class-like (public por default — solo rechazar private/internal/protected):
#       (data|sealed|abstract|open|inline|value|annotation|enum)? (class|object|interface) Name
#    Top-level fun:
#       fun name(...)
#    Receiver fun (top-level fun on a type):
#       fun Foo.bar(...)
awk '
    /^[[:space:]]*(private|internal|protected)[[:space:]]/ { next }
    /^(public[[:space:]]+)?...(class|object|interface)[[:space:]]+[A-Z]/ { extract symbol }
    /^fun[[:space:]]+[a-zA-Z_]/ { extract symbol }
'

# 3. Reachability sources (in priority order):
#    a. ENTRY_POINTS verbatim files
#    b. AndroidManifest.xml (manifest-declared components)
#    c. Files matching Koin DSL pattern (auto-discovered)
#    d. Fallback: any production .kt under SCAN_ROOT, excluding the defining file

# 4. Per-symbol: grep -wF on (a)+(b)+(c) fast-path; if not found, grep -rwlF over (d).
#    Symbol is a ghost if no match anywhere.
```

### Entry-point auto-detección

`install.sh kotlin-android` busca:
- `app/src/main/java/**/MainActivity.kt` (cualquier subdirectorio)
- `app/src/main/java/**/*Application.kt` (Application class)
- `app/src/main/java/**/*App.kt` que NO sea `*Application.kt` (top-level Compose graph composable)

Para proyectos no estándar, edita `project.conf` después del install. El
campo `MANIFEST_PATH` default es `app/src/main/AndroidManifest.xml` y se puede
override.

### Skip-list

Generic Kotlin/Android infrastructure que produce noise sin señal:
- `R`, `BuildConfig` (generated)
- `Companion`, `invoke` (operator fn names)
- `Color`, `Theme`, `Type`, `Typography`, `Shapes` (Compose theme conventions)
- Tipos primitivos: `String`, `Int`, `Long`, etc. (rare false positives via top-level extension fns)

Project-specific names (Application class, NavGraph) NO van en la skip-list —
van en `ENTRY_POINTS`, donde se exentan por archivo en lugar de por nombre.

### Limitaciones específicas

- **Reflection / Class.forName(...)**: el checker no resuelve strings
  dinámicos. Si tu código hace `Class.forName("$BuildConfig.APPLICATION_ID.MainActivity")`,
  el simple-name `MainActivity` puede o no aparecer textualmente en el código.
  En la práctica, casi siempre aparece — es un edge case raro.
- **kotlinx-serialization polymorphic discriminators**: si tienes
  `polymorphic { subclass(Foo::class) }` en un `SerializersModule`, `Foo` se
  cuenta como reachable (el módulo lo menciona). OK.
- **@Composable `@Preview` functions**: el checker NO distingue `@Composable`
  con/sin `@Preview`. Una `@Preview` es por convención dev-only — pero su
  existencia hace que un componente sin caller real luzca "wired" si la
  preview está en el mismo archivo y se llama sí misma. **Mitigación**: el
  checker excluye self-mentions (file-defining-symbol) explícitamente; un
  Preview en el mismo archivo NO cuenta como reachable.
- **Dynamic feature modules**: el scan default es `app/src/main/java`. Si
  usas dynamic feature modules con `feature/src/main/java`, override
  `SRC_GLOBS` o múltiples scan roots (no soportado nativamente — adapta el
  checker).

### Validado contra

Drivox CRM Android (production app, repo: bot202102/Drivox):
- 604 archivos `.kt` en `app/src/main/java/`
- 8 Koin module files bajo `core/di/`
- 3 entry-points: `MainActivity.kt`, `MoytrixApp.kt`, `MoytrixApplication.kt`
- 48 ghosts heredados en baseline inicial (incluye Night Ledger parallel-unapplied
  theme components, exception classes used via Java reflection, DTOs accedidos
  vía kotlinx-serialization sin nombre explícito)
- Tiempo de baseline run: 7.5s
- Tiempo de Stop hook (incremental, ~5 nuevos symbols): ~0.5s

### Entry-point candidates

- `app/src/main/java/com/example/app/MainActivity.kt` (single Activity con Compose)
- `app/src/main/java/com/example/app/MyApplication.kt` (Application class — registra Koin modules)
- `app/src/main/java/com/example/app/MyApp.kt` (top-level `@Composable fun MyApp()` con NavHost)
- Optionally: archivos de `BroadcastReceiver` críticos si tu lógica de wakeup vive ahí

### Archivos

- `.claude/hooks/lang/kotlin-android.sh` — checker

## Agregar soporte para un lenguaje nuevo

1. Crea `.claude/hooks/lang/<lang>.sh` siguiendo el contrato arriba
2. Agrega el case en `.claude/hooks/integration-gate.sh`:
   ```bash
   case "$LANG" in
       ...
       <lang>) bash "$HOOKS_DIR/lang/<lang>.sh" ;;
   esac
   ```
3. Documenta el mecanismo en este archivo
4. Agrega un ejemplo de `project.conf` para el lenguaje en `project.conf.example`

## Referencias

- Cómo funcionan los hooks de Claude Code: https://docs.claude.com/en/docs/claude-code/hooks
- Exit codes en hooks: `exit 2` → feedback a Claude, bloquea operación
- Settings file: https://docs.claude.com/en/docs/claude-code/settings
