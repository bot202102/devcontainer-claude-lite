#!/usr/bin/env bash
# python.sh — public top-level symbols without reachability.
# POSIX + python3. Loud failure on missing tools.

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "python.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "python.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

if [ -z "$SRC_GLOBS" ]; then
    if [ -d "src" ]; then SCAN_ROOTS=(src)
    elif [ -d "lib" ]; then SCAN_ROOTS=(lib)
    else SCAN_ROOTS=(.)
    fi
else
    # shellcheck disable=SC2206
    SCAN_ROOTS=($SRC_GLOBS)
fi

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS"' EXIT

find "${SCAN_ROOTS[@]}" -type f -name '*.py' 2>/dev/null | \
    grep -vE '(test_|_test\.py$|/tests/|/__pycache__/|/venv/|/\.venv/|/node_modules/|/\.tox/|/build/|/dist/)' \
    > "$TMP_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

# Extract public top-level symbols via Python AST (robust vs grep)
python3 - "$TMP_FILES" > "$TMP_SYMS" <<'PYEOF'
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

[ ! -s "$TMP_SYMS" ] && exit 0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    case "$symbol" in
        main|Config|Error|Result|create_app|app|router|handler)
            continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        if grep -qw "$symbol" "$ep" 2>/dev/null; then
            found=1; break
        fi
        ep_dir=$(dirname "$ep")
        if find "$ep_dir" -name '*.py' -type f 2>/dev/null | while IFS= read -r f; do
            if grep -qw "$symbol" "$f" 2>/dev/null; then echo 1; break; fi
        done | grep -q '1'; then
            found=1; break
        fi
    done

    [ "$found" = "0" ] && echo "$line"
done < "$TMP_SYMS"
