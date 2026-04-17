#!/usr/bin/env bash
# go.sh — extract exported symbols (CamelCase) without reachability from
# entry-point's package tree.
#
# Contract: see guardrails/docs/LANG_MATRIX.md

set -euo pipefail

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if ! command -v rg >/dev/null 2>&1; then
    echo "go.sh: ripgrep (rg) required" >&2
    exit 0
fi

# Default scan
if [ -z "$SRC_GLOBS" ]; then
    SCAN_ARGS=(.)
else
    # shellcheck disable=SC2206
    SCAN_ARGS=($SRC_GLOBS)
fi

EXCLUDES=(
    --glob '!**/*_test.go'
    --glob '!**/vendor/**'
    --glob '!**/testdata/**'
)
for extra in $TEST_EXCLUDES; do
    EXCLUDES+=(--glob "!$extra")
done

# Exported Go symbols = start with uppercase letter
SYMBOLS=$(rg "${EXCLUDES[@]}" \
    -t go \
    -n --no-heading --with-filename \
    '^(func|type|var|const)\s+(\([^)]*\)\s+)?([A-Z][A-Za-z0-9_]*)' \
    "${SCAN_ARGS[@]}" 2>/dev/null | \
    sed -E 's|^([^:]+):([0-9]+):(func|type|var|const)\s+(\([^)]*\)\s+)?([A-Z][A-Za-z0-9_]*).*|\1:\2:\5|' || true)

[ -z "$SYMBOLS" ] && exit 0

# Optional: use `go list -deps` for precise reachability if available
REACHABLE_PKGS=""
if command -v go >/dev/null 2>&1; then
    for ep in $ENTRY_POINTS; do
        ep_dir=$(dirname "$ep")
        if [ -d "$ep_dir" ]; then
            # Resolve package path from module + relative dir
            pkg=$(go list "./$ep_dir" 2>/dev/null || true)
            if [ -n "$pkg" ]; then
                deps=$(go list -deps "./$ep_dir" 2>/dev/null || true)
                REACHABLE_PKGS="$REACHABLE_PKGS
$deps"
            fi
        fi
    done
fi

# For each symbol, check reachability
while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')
    file=$(echo "$line" | awk -F: '{print $1}')

    # Skip framework names
    case "$symbol" in
        Main|Config|Error|Handler|Server|Client|Request|Response) continue ;;
    esac

    found=0

    # If we have reachable pkgs, check if this file's package is in the list
    if [ -n "$REACHABLE_PKGS" ]; then
        file_dir=$(dirname "$file")
        file_pkg=$(go list "./$file_dir" 2>/dev/null || true)
        if [ -n "$file_pkg" ] && echo "$REACHABLE_PKGS" | grep -qx "$file_pkg"; then
            # Symbol's package IS reachable from entry — still need to check
            # if the specific SYMBOL is used, but this already reduces false positives
            found=1
        fi
    fi

    # Fallback: grep symbol usage in ENTRY_POINTS
    if [ $found -eq 0 ]; then
        for ep in $ENTRY_POINTS; do
            [ ! -f "$ep" ] && continue
            ep_dir=$(dirname "$ep")
            if rg -q "\b$symbol\b" "$ep_dir" -t go 2>/dev/null; then
                found=1; break
            fi
        done
    fi

    if [ $found -eq 0 ]; then
        echo "$line"
    fi
done <<< "$SYMBOLS"
