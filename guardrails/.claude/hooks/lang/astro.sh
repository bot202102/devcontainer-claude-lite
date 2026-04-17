#!/usr/bin/env bash
# astro.sh — ghost-symbol checker for Astro projects.
#
# Unlike node.sh (which assumes a single ENTRY_POINTS file like src/index.ts),
# Astro projects have MANY implicit entry-points:
#   - src/pages/**/*.astro           (file-based routing, each is a page)
#   - src/pages/**/*.{ts,tsx,js,mjs} (API routes / dynamic endpoints)
#   - src/middleware.ts              (request middleware)
#   - astro.config.{mjs,ts,js}       (build-time config)
#
# Model: every file under src/pages/ + middleware + astro.config is a root.
# A symbol defined OUTSIDE pages/ is "wired" if it is referenced anywhere
# under src/ (plus astro.config) in a file OTHER than its own defining file,
# excluding tests and mocks.
#
# This is an over-approximation (not true module reachability) because
# barrel re-exports (`export * from './X'`) + `@/` alias resolution would
# require a full import-graph walker. The baseline mechanism absorbs the
# false positives: only NEW ghosts vs baseline block the Stop gate.
#
# ENTRY_POINTS env var is OPTIONAL for astro — defaults auto-discover.
# Override it if your project uses non-standard page roots.
#
# Contract: stdout = one ghost per line as "file:line:symbol". exit 0.

set -u

SRC_ROOT="${SRC_GLOBS:-src}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

for bin in grep find awk tr sort; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "astro.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

[ ! -d "$SRC_ROOT" ] && exit 0

TMP_DEFS=$(mktemp)
TMP_DEFS_FILES=$(mktemp)
TMP_CORPUS=$(mktemp)
TMP_CORPUS_FILES=$(mktemp)
trap 'rm -f "$TMP_DEFS" "$TMP_DEFS_FILES" "$TMP_CORPUS" "$TMP_CORPUS_FILES"' EXIT

EXCLUDE_RE='(/node_modules/|/dist/|/build/|/\.astro/|/\.next/|/__tests__/|/__mocks__/|\.test\.|\.spec\.|\.d\.ts$)'

# 1. Symbol-definition sources: every .ts/.tsx/.js/.jsx/.mjs under src/
#    OUTSIDE pages/ (pages are roots, they consume symbols, not define them
#    for reuse). Tests excluded.
find "$SRC_ROOT" -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) \
    2>/dev/null | grep -vE "$EXCLUDE_RE" | grep -v "^${SRC_ROOT}/pages/" \
    > "$TMP_DEFS_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_DEFS_FILES" > "${TMP_DEFS_FILES}.new" 2>/dev/null \
            || cp "$TMP_DEFS_FILES" "${TMP_DEFS_FILES}.new"
        mv "${TMP_DEFS_FILES}.new" "$TMP_DEFS_FILES"
    done
fi

[ ! -s "$TMP_DEFS_FILES" ] && exit 0

# Extract top-level exported symbols. Heuristic grep — suffices in practice.
while IFS= read -r f; do
    awk -v file="$f" '
        /^export[[:space:]]+(const|let|var|function|async[[:space:]]+function|class|enum|interface|type)[[:space:]]+[A-Za-z_$]/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^(const|let|var|function|class|enum|interface|type)$/ && (i+1) <= NF) {
                    name = $(i+1)
                    sub(/[^A-Za-z0-9_$].*$/, "", name)
                    if (length(name) > 0) print file ":" NR ":" name
                    break
                }
            }
        }
    ' "$f"
done < "$TMP_DEFS_FILES" > "$TMP_DEFS"

[ ! -s "$TMP_DEFS" ] && exit 0

# 2. Grep corpus: all source-like files under src/ (including pages + .astro),
#    plus middleware + astro.config at project root. Tests excluded.
find "$SRC_ROOT" -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.astro' \) \
    2>/dev/null | grep -vE "$EXCLUDE_RE" \
    > "$TMP_CORPUS_FILES"

for root_file in middleware.ts middleware.js astro.config.mjs astro.config.ts astro.config.js; do
    [ -f "$root_file" ] && echo "$root_file" >> "$TMP_CORPUS_FILES"
done

# 3. Tokenize corpus into "token:file" pairs (token = identifier-like word,
#    file = which corpus file contains it). Each unique per file.
while IFS= read -r f; do
    tr -c 'A-Za-z0-9_$' '\n' < "$f" 2>/dev/null \
        | awk 'length >= 2 && /^[A-Za-z_$]/' \
        | sort -u \
        | awk -v file="$f" '{print $0 ":" file}'
done < "$TMP_CORPUS_FILES" > "$TMP_CORPUS"

# 4. Ghost = symbol whose name does NOT appear in the corpus outside its
#    own defining file(s). One awk pass: build the def map from TMP_DEFS,
#    stream TMP_CORPUS, mark wired ones, emit the unmarked originals.
awk -F: '
    NR == FNR {
        sym = $NF
        orig[sym] = (sym in orig ? orig[sym] "\n" : "") $0
        defn[sym] = (sym in defn ? defn[sym] "|" $1 : $1)
        next
    }
    {
        tok = $1
        file = $2
        if (tok in defn) {
            is_self = 0
            n = split(defn[tok], arr, "|")
            for (i = 1; i <= n; i++) if (arr[i] == file) { is_self = 1; break }
            if (!is_self) wired[tok] = 1
        }
    }
    END {
        skip = "|default|main|Props|State|Config|Error|Type|Schema|Layout|GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD|ALL|prerender|getStaticPaths|all|onRequest|sequence|defineMiddleware|defineConfig|"
        for (sym in orig) {
            if (sym in wired) continue
            if (index(skip, "|" sym "|") > 0) continue
            # orig[sym] may contain multiple "file:line:symbol" entries
            # separated by "\n"; print each on its own line, no blanks.
            n = split(orig[sym], lines, "\n")
            for (i = 1; i <= n; i++) {
                if (length(lines[i]) > 0) print lines[i]
            }
        }
    }
' "$TMP_DEFS" "$TMP_CORPUS"

exit 0
