#!/usr/bin/env bash
# java.sh — public classes/interfaces/enums without reachability.
# POSIX-only, no ripgrep. Loud failure on missing tools.

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "java.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "java.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

if [ -z "$SRC_GLOBS" ]; then
    if [ -d "src/main/java" ]; then SCAN_ROOT="src/main/java"
    else SCAN_ROOT="."
    fi
else
    SCAN_ROOT="$SRC_GLOBS"
fi

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS"' EXIT

find "$SCAN_ROOT" -type f -name '*.java' 2>/dev/null | \
    grep -vE '(/src/test/|/target/|/build/|Test\.java$|Tests\.java$|IT\.java$)' > "$TMP_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

while IFS= read -r file; do
    awk -v file="$file" '
        /public[[:space:]]+(class|interface|enum|record)[[:space:]]+[A-Z][A-Za-z0-9_]*/ {
            match($0, /(class|interface|enum|record)[[:space:]]+[A-Z][A-Za-z0-9_]*/)
            s = substr($0, RSTART, RLENGTH)
            sub(/^(class|interface|enum|record)[[:space:]]+/, "", s)
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
        Main|Application|Config|Error|Handler|Request|Response|Builder|String)
            continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        if grep -qw "$symbol" "$ep" 2>/dev/null; then
            found=1; break
        fi
        ep_dir=$(dirname "$ep")
        if find "$ep_dir" -name '*.java' -type f 2>/dev/null | while IFS= read -r f; do
            if grep -qw "$symbol" "$f" 2>/dev/null; then echo 1; break; fi
        done | grep -q '1'; then
            found=1; break
        fi
    done

    [ "$found" = "0" ] && echo "$line"
done < "$TMP_SYMS"
