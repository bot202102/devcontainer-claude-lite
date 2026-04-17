#!/usr/bin/env bash
# python.sh — extract public (no _prefix) top-level symbols without
# import-path reachability from ENTRY_POINTS.
#
# Contract: see guardrails/docs/LANG_MATRIX.md
# Invoked by: integration-gate.sh, ghost-report.sh

set -euo pipefail

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python.sh: python3 required but not found" >&2
    exit 0
fi

# Default scan roots
if [ -z "$SRC_GLOBS" ]; then
    if [ -d "src" ]; then
        SCAN_ROOTS=(src)
    elif [ -d "lib" ]; then
        SCAN_ROOTS=(lib)
    else
        # Use project root but exclude common noise
        SCAN_ROOTS=(.)
    fi
else
    # shellcheck disable=SC2206
    SCAN_ROOTS=($SRC_GLOBS)
fi

# Build list of .py files excluding tests and common noise
TMP_FILES=$(mktemp)
trap 'rm -f "$TMP_FILES"' EXIT

# Find files, exclude tests + venv + __pycache__
find "${SCAN_ROOTS[@]}" -name '*.py' -type f 2>/dev/null | \
    grep -v -E '(test_|_test\.py|/tests/|/__pycache__/|/venv/|/\.venv/|/node_modules/|/\.tox/|/build/|/dist/)' \
    > "$TMP_FILES" || true

[ ! -s "$TMP_FILES" ] && exit 0

# Apply user excludes
if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "$TMP_FILES.new" || true
        mv "$TMP_FILES.new" "$TMP_FILES"
    done
fi

# Extract public top-level symbols via AST
SYMBOLS=$(python3 - "$TMP_FILES" <<'PYEOF'
import ast, sys

with open(sys.argv[1]) as f:
    files = [l.strip() for l in f if l.strip()]

for path in files:
    try:
        with open(path, encoding='utf-8') as fp:
            tree = ast.parse(fp.read(), path)
    except Exception:
        continue
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if not node.name.startswith('_'):
                print(f"{path}:{node.lineno}:{node.name}")
PYEOF
)

[ -z "$SYMBOLS" ] && exit 0

# For each symbol, check reachability from ENTRY_POINTS
while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    # Skip common framework/dunder names
    case "$symbol" in
        main|Config|Error|Result|create_app|app|router|handler) continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        ep_dir=$(dirname "$ep")
        if grep -rq "\b$symbol\b" "$ep" 2>/dev/null; then
            found=1; break
        fi
        # Also check package the entry-point lives in
        if grep -rq "\b$symbol\b" "$ep_dir" --include='*.py' 2>/dev/null; then
            found=1; break
        fi
    done

    if [ $found -eq 0 ]; then
        echo "$line"
    fi
done <<< "$SYMBOLS"
