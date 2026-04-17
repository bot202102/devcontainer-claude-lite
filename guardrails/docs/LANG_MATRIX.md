# Matrix de checkers por lenguaje

Cada checker en `.claude/hooks/lang/<lang>.sh` implementa una heurística para detectar
"símbolos públicos nuevos sin call-site alcanzable desde el entry-point productivo".

El invariante es agnóstico. El mecanismo varía según el build system y la
filosofía de visibilidad de cada lenguaje.

## Contrato de cada checker

**Input**: variables de entorno definidas en `project.conf`:
- `ENTRY_POINTS` — paths relativos (space-separated) al entry-point productivo
- `SRC_GLOBS` — patrón de archivos a escanear (default: auto por lenguaje)
- `TEST_EXCLUDES` — patrones a excluir del scan (default: auto por lenguaje)

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

### Entry-point candidates
- Campo `"main"` en `package.json`
- Campo `"bin"` en `package.json` (para CLIs)
- Campo `"start"` en `scripts`
- Archivo principal de Next.js / Express / Fastify

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
