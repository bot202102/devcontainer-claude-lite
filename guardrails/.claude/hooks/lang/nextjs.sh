#!/usr/bin/env bash
# nextjs.sh — ghost-symbol checker for Next.js App Router projects.
#
# Adapted from astro.sh. The model is the same: file-based routing means
# there's no single main entry — every file under app/ is a root. A symbol
# defined OUTSIDE app/ is "wired" if it's referenced anywhere under the
# source tree (in a file OTHER than its own defining file), excluding tests.
#
# Next.js roots auto-discovered:
#   - <src>/app/**/page.{ts,tsx,js,jsx}       (page routes)
#   - <src>/app/**/layout.{ts,tsx,js,jsx}     (layouts)
#   - <src>/app/**/route.{ts,js}              (API route handlers)
#   - <src>/app/**/loading.{ts,tsx}           (loading UI)
#   - <src>/app/**/error.{ts,tsx}             (error boundaries)
#   - <src>/app/**/not-found.{ts,tsx}         (404)
#   - <src>/app/**/template.{ts,tsx}          (templates)
#   - middleware.{ts,js}                      (edge middleware)
#   - next.config.{js,mjs,ts,cjs}             (build config)
#   - instrumentation.{ts,js}                 (observability)
#
# This is a heuristic over-approximation (barrel re-exports / path-aliases
# require a full import-graph walker). Baseline mechanism absorbs false
# positives — only NEW ghosts vs baseline block the Stop gate.
#
# Env vars:
#   SRC_GLOBS      — root of source tree (default: "src"; for Next.js at
#                    project root use e.g. "frontend/src").
#   TEST_EXCLUDES  — extra glob patterns to filter out.
#
# Contract: stdout = one ghost per line as "file:line:symbol". exit 0.

set -u

SRC_ROOT="${SRC_GLOBS:-src}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

for bin in grep find awk tr sort; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "nextjs.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

[ ! -d "$SRC_ROOT" ] && exit 0

TMP_DEFS=$(mktemp)
TMP_DEFS_FILES=$(mktemp)
TMP_CORPUS=$(mktemp)
TMP_CORPUS_FILES=$(mktemp)
trap 'rm -f "$TMP_DEFS" "$TMP_DEFS_FILES" "$TMP_CORPUS" "$TMP_CORPUS_FILES"' EXIT

EXCLUDE_RE='(/node_modules/|/dist/|/build/|/\.next/|/\.turbo/|/__tests__/|/__mocks__/|\.test\.|\.spec\.|\.d\.ts$|/e2e/)'

# 1. Symbol-definition sources: every source file under $SRC_ROOT OUTSIDE
#    app/ AND OUTSIDE pages/ (pages router, if also in use). Routed files
#    are roots that CONSUME symbols, not define reusable ones.
find "$SRC_ROOT" -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) \
    2>/dev/null | grep -vE "$EXCLUDE_RE" \
    | grep -v "^${SRC_ROOT}/app/" \
    | grep -v "^${SRC_ROOT}/pages/" \
    > "$TMP_DEFS_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_DEFS_FILES" > "${TMP_DEFS_FILES}.new" 2>/dev/null \
            || cp "$TMP_DEFS_FILES" "${TMP_DEFS_FILES}.new"
        mv "${TMP_DEFS_FILES}.new" "$TMP_DEFS_FILES"
    done
fi

[ ! -s "$TMP_DEFS_FILES" ] && exit 0

# Extract top-level exported symbols. Heuristic grep.
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

# 2. Grep corpus: all source-like files under $SRC_ROOT (INCLUDING app/pages),
#    plus Next.js root-level entry files (middleware, next.config, instrumentation).
find "$SRC_ROOT" -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) \
    2>/dev/null | grep -vE "$EXCLUDE_RE" \
    > "$TMP_CORPUS_FILES"

# Next.js may have root-level files either at project root OR at the parent
# of $SRC_ROOT (e.g. frontend/next.config.js when SRC_GLOBS=frontend/src).
SRC_PARENT="$(dirname "$SRC_ROOT")"
for root_file in \
    middleware.ts middleware.js \
    next.config.js next.config.mjs next.config.ts next.config.cjs \
    instrumentation.ts instrumentation.js \
    "$SRC_PARENT/middleware.ts" "$SRC_PARENT/middleware.js" \
    "$SRC_PARENT/next.config.js" "$SRC_PARENT/next.config.mjs" "$SRC_PARENT/next.config.ts" "$SRC_PARENT/next.config.cjs" \
    "$SRC_PARENT/instrumentation.ts" "$SRC_PARENT/instrumentation.js"
do
    [ -f "$root_file" ] && echo "$root_file" >> "$TMP_CORPUS_FILES"
done

# 3. Tokenize corpus into "token:file" pairs.
while IFS= read -r f; do
    tr -c 'A-Za-z0-9_$' '\n' < "$f" 2>/dev/null \
        | awk 'length >= 2 && /^[A-Za-z_$]/' \
        | sort -u \
        | awk -v file="$f" '{print $0 ":" file}'
done < "$TMP_CORPUS_FILES" > "$TMP_CORPUS"

# 4. Ghost = symbol whose name does NOT appear in the corpus outside its
#    own defining file(s).
#
# Skip list: Next.js convention-based exports that are contracts with the
# framework runtime (not "called" from other code but still wired):
#   default, generateMetadata, generateStaticParams, generateViewport,
#   metadata, viewport, revalidate, dynamic, dynamicParams, fetchCache,
#   runtime, preferredRegion, maxDuration, GET/POST/PUT/DELETE/PATCH/
#   OPTIONS/HEAD for route handlers, middleware, config.
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
        skip = "|default|Props|State|Config|Error|Type|Schema|Layout|middleware|config|metadata|viewport|revalidate|dynamic|dynamicParams|fetchCache|runtime|preferredRegion|maxDuration|generateMetadata|generateStaticParams|generateViewport|GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD|ALL|"
        for (sym in orig) {
            if (sym in wired) continue
            if (index(skip, "|" sym "|") > 0) continue
            n = split(orig[sym], lines, "\n")
            for (i = 1; i <= n; i++) {
                if (length(lines[i]) > 0) print lines[i]
            }
        }
    }
' "$TMP_DEFS" "$TMP_CORPUS"

exit 0
