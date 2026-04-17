#!/usr/bin/env bash
# go.sh — exported Go symbols (CamelCase) without reachability.
# POSIX-only, no ripgrep. Loud failure on missing tools.

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "go.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "go.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

SCAN_ROOT="${SRC_GLOBS:-.}"

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS"' EXIT

find "$SCAN_ROOT" -type f -name '*.go' 2>/dev/null | \
    grep -vE '(_test\.go$|/vendor/|/testdata/)' > "$TMP_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

while IFS= read -r file; do
    awk -v file="$file" '
        /^(func|type|var|const)[[:space:]]+(\([^)]*\)[[:space:]]+)?[A-Z][A-Za-z0-9_]*/ {
            match($0, /(func|type|var|const)[[:space:]]+(\([^)]*\)[[:space:]]+)?[A-Z][A-Za-z0-9_]*/)
            s = substr($0, RSTART, RLENGTH)
            sub(/^(func|type|var|const)[[:space:]]+/, "", s)
            sub(/^\([^)]*\)[[:space:]]+/, "", s)
            sub(/[^A-Za-z0-9_].*$/, "", s)
            if (length(s) > 0) print file ":" NR ":" s
        }
    ' "$file"
done < "$TMP_FILES" > "$TMP_SYMS"

[ ! -s "$TMP_SYMS" ] && exit 0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    case "$symbol" in
        Main|Config|Error|Handler|Server|Client|Request|Response|String|New)
            continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        if grep -qw "$symbol" "$ep" 2>/dev/null; then
            found=1; break
        fi
        ep_dir=$(dirname "$ep")
        if find "$ep_dir" -name '*.go' -type f 2>/dev/null | while IFS= read -r f; do
            if grep -qw "$symbol" "$f" 2>/dev/null; then echo 1; break; fi
        done | grep -q '1'; then
            found=1; break
        fi
    done

    [ "$found" = "0" ] && echo "$line"
done < "$TMP_SYMS"
