#!/usr/bin/env bash
# node.sh — extract exported symbols without call-site in ENTRY_POINTS.
# Contract: see guardrails/docs/LANG_MATRIX.md
# POSIX-only. No ripgrep dependency. Loud failure on missing tools.

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "node.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "node.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

if [ -z "$SRC_GLOBS" ]; then
    if [ -d "src" ]; then SCAN_ROOT="src"
    elif [ -d "packages" ]; then SCAN_ROOT="packages"
    elif [ -d "app" ]; then SCAN_ROOT="app"
    else SCAN_ROOT="."
    fi
else
    SCAN_ROOT="$SRC_GLOBS"
fi

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS"' EXIT

find "$SCAN_ROOT" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) 2>/dev/null | \
    grep -vE '(/node_modules/|/dist/|/build/|/\.next/|/__tests__/|/__mocks__/|\.test\.|\.spec\.)' \
    > "$TMP_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

while IFS= read -r file; do
    awk -v file="$file" '
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
    ' "$file"
done < "$TMP_FILES" > "$TMP_SYMS"

[ ! -s "$TMP_SYMS" ] && exit 0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')
    # Defining file = everything before the trailing :line:symbol fields.
    defining_file=$(echo "$line" | sed -E 's/:[0-9]+:[^:]+$//')

    case "$symbol" in
        default|main|Props|State|Config|Error|Type|Interface|Schema|Router|async|function)
            continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        # Direct entry-point reference. Skip self-match: if the entry-point
        # IS the file that defines the symbol, the export line itself trivially
        # contains the name.
        if [ "$ep" != "$defining_file" ] && grep -qw "$symbol" "$ep" 2>/dev/null; then
            found=1; break
        fi
        ep_dir=$(dirname "$ep")
        # Recursive scan of the entry-point's directory MUST exclude the
        # symbol's own defining file. Without this exclusion, every export
        # self-matches in its own definition (`export function foo` contains
        # the token `foo`), so `found=1` always — and the gate becomes a
        # no-op for `node` mode.
        if find "$ep_dir" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) ! -path "$defining_file" 2>/dev/null | while IFS= read -r f; do
            if grep -qw "$symbol" "$f" 2>/dev/null; then echo 1; break; fi
        done | grep -q '1'; then
            found=1; break
        fi
    done

    [ "$found" = "0" ] && echo "$line"
done < "$TMP_SYMS"
