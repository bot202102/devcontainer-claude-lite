#!/usr/bin/env bash
# node.sh — extract exported symbols without call-site in ENTRY_POINTS.
#
# Works for JS/TS, CommonJS or ESM. Heuristic grep (not AST) — suficient para
# feedback dev-time, not compilador-grade.
#
# Contract: see guardrails/docs/LANG_MATRIX.md

set -euo pipefail

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if ! command -v rg >/dev/null 2>&1; then
    echo "node.sh: ripgrep (rg) required but not found" >&2
    exit 0
fi

# Default scan roots
if [ -z "$SRC_GLOBS" ]; then
    if [ -d "src" ]; then
        SCAN_ARGS=(src)
    elif [ -d "packages" ]; then
        SCAN_ARGS=(packages)
    elif [ -d "app" ]; then
        SCAN_ARGS=(app)
    else
        SCAN_ARGS=(.)
    fi
else
    # shellcheck disable=SC2206
    SCAN_ARGS=($SRC_GLOBS)
fi

EXCLUDES=(
    --glob '!**/node_modules/**'
    --glob '!**/dist/**'
    --glob '!**/build/**'
    --glob '!**/.next/**'
    --glob '!**/*.test.ts'
    --glob '!**/*.test.tsx'
    --glob '!**/*.test.js'
    --glob '!**/*.spec.ts'
    --glob '!**/*.spec.tsx'
    --glob '!**/*.spec.js'
    --glob '!**/__tests__/**'
    --glob '!**/__mocks__/**'
)
for extra in $TEST_EXCLUDES; do
    EXCLUDES+=(--glob "!$extra")
done

# Extract named exports (not default). Default exports are commonly re-exported
# so ghost detection is lower value there.
SYMBOLS=$(rg "${EXCLUDES[@]}" \
    --type-add 'web:*.{ts,tsx,js,jsx,mjs,cjs}' -t web \
    -n --no-heading --with-filename \
    'export\s+(const|let|var|function|async\s+function|class|enum|interface|type)\s+([A-Za-z_$][A-Za-z0-9_$]*)' \
    "${SCAN_ARGS[@]}" 2>/dev/null | \
    sed -E 's|^([^:]+):([0-9]+):.*export\s+\w+(\s+\w+)?\s+([A-Za-z_$][A-Za-z0-9_$]*).*|\1:\2:\4|' || true)

# Also capture `export { foo, bar }` re-exports
RE_EXPORTS=$(rg "${EXCLUDES[@]}" \
    --type-add 'web:*.{ts,tsx,js,jsx,mjs,cjs}' -t web \
    -n --no-heading --with-filename \
    'export\s*\{([^}]+)\}' \
    "${SCAN_ARGS[@]}" 2>/dev/null || true)

[ -z "$SYMBOLS" ] && [ -z "$RE_EXPORTS" ] && exit 0

# For each symbol, check reachability from ENTRY_POINTS
while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    # Skip framework / build artifact names commonly false-positive
    case "$symbol" in
        default|main|Props|State|Config|Error|Type|Interface|Schema|Router) continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        ep_dir=$(dirname "$ep")
        if rg -q "\b$symbol\b" "$ep" 2>/dev/null; then
            found=1; break
        fi
        if rg -q "\b$symbol\b" "$ep_dir" --glob '*.{ts,tsx,js,jsx}' 2>/dev/null; then
            found=1; break
        fi
    done

    if [ $found -eq 0 ]; then
        echo "$line"
    fi
done <<< "$SYMBOLS"
