#!/usr/bin/env bash
# java.sh — extract public classes/interfaces without import in the package
# tree reachable from the entry-point class.
#
# Heuristic — Java reflection & Spring DI can hide dependencies.
# Falsos positivos esperados con heavy reflection; falsos negativos raros.
#
# Contract: see guardrails/docs/LANG_MATRIX.md

set -euo pipefail

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if ! command -v rg >/dev/null 2>&1; then
    echo "java.sh: ripgrep (rg) required" >&2
    exit 0
fi

if [ -z "$SRC_GLOBS" ]; then
    if [ -d "src/main/java" ]; then
        SCAN_ARGS=(src/main/java)
    else
        SCAN_ARGS=(.)
    fi
else
    # shellcheck disable=SC2206
    SCAN_ARGS=($SRC_GLOBS)
fi

EXCLUDES=(
    --glob '!**/src/test/**'
    --glob '!**/target/**'
    --glob '!**/build/**'
    --glob '!**/*Test.java'
    --glob '!**/*Tests.java'
    --glob '!**/*IT.java'
)
for extra in $TEST_EXCLUDES; do
    EXCLUDES+=(--glob "!$extra")
done

# Extract public class/interface/enum definitions
SYMBOLS=$(rg "${EXCLUDES[@]}" \
    -t java \
    -n --no-heading --with-filename \
    'public\s+(class|interface|enum|record)\s+([A-Z][A-Za-z0-9_]*)' \
    "${SCAN_ARGS[@]}" 2>/dev/null | \
    sed -E 's|^([^:]+):([0-9]+):.*public\s+(class|interface|enum|record)\s+([A-Z][A-Za-z0-9_]*).*|\1:\2:\4|' || true)

[ -z "$SYMBOLS" ] && exit 0

# For each symbol, check reachability from ENTRY_POINTS
while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    # Skip common names
    case "$symbol" in
        Main|Application|Config|Error|Handler|Request|Response|Builder) continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        ep_dir=$(dirname "$ep")
        # Check import + usage in ENTRY_POINTS and its package
        if rg -q "\b$symbol\b" "$ep" 2>/dev/null; then
            found=1; break
        fi
        if rg -q "\b$symbol\b" "$ep_dir" -t java 2>/dev/null; then
            found=1; break
        fi
    done

    if [ $found -eq 0 ]; then
        echo "$line"
    fi
done <<< "$SYMBOLS"
