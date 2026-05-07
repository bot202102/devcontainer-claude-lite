#!/usr/bin/env bash
# rust.sh — extract public symbols without call-site in ENTRY_POINTS.
#
# Contract: see guardrails/docs/LANG_MATRIX.md
# Invoked by: integration-gate.sh, ghost-report.sh
#
# Output (stdout): one ghost per line, format "<file>:<line>:<symbol>"
# Env vars: ENTRY_POINTS (required), SRC_GLOBS (optional), TEST_EXCLUDES (optional)
#
# Uses only POSIX `find` + `grep` + `awk`. No ripgrep dependency.
# set -u for undefined-var safety; NOT set -e/pipefail (head|pipe gotchas).

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "rust.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "rust.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

# Default scan root
if [ -z "$SRC_GLOBS" ]; then
    if [ -d "crates" ]; then
        SCAN_ROOT="crates"
    elif [ -d "src" ]; then
        SCAN_ROOT="src"
    else
        SCAN_ROOT="."
    fi
else
    SCAN_ROOT="$SRC_GLOBS"
fi

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS"' EXIT

# Collect source files (exclude tests, target, benches, examples)
find "$SCAN_ROOT" -type f -name '*.rs' 2>/dev/null | \
    grep -vE '(/target/|/tests/|/examples/|/benches/|_test\.rs$|test_.*\.rs$)' \
    > "$TMP_FILES"

# Apply user-specified excludes
if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || \
            cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

# Extract `pub (fn|struct|enum|trait) <Name>` — single awk pass, no pipes
while IFS= read -r file; do
    awk -v file="$file" '
        /^pub[[:space:]]+(fn|struct|enum|trait)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            # Skip #[cfg(test)] blocks — simple heuristic
            if (in_test) next
            match($0, /(fn|struct|enum|trait)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)
            sub(/^.*(fn|struct|enum|trait)[[:space:]]+/, "", $0)
            sub(/[^A-Za-z0-9_].*$/, "", $0)
            if (length($0) > 0) print file ":" NR ":" $0
        }
        /#\[cfg\(test\)\]/ { in_test = 1 }
        /^}/ { if (in_test) in_test = 0 }
    ' "$file"
done < "$TMP_FILES" > "$TMP_SYMS"

[ ! -s "$TMP_SYMS" ] && exit 0

# For each symbol, check if it's referenced in any ENTRY_POINTS file or its
# sibling modules (same crate src dir).
#
# SKIP_SELF (default 1, matching python.sh): when checking siblings, exclude
# the file where the symbol is defined — otherwise the definition itself
# (`pub fn foo`) matches `grep -w foo` and the symbol is incorrectly marked
# as reachable. A symbol called only from its own file (recursion) does not
# count as production-reachable; a real caller must live elsewhere.
SKIP_SELF="${SKIP_SELF:-1}"

while IFS= read -r line; do
    [ -z "$line" ] && continue
    definer_file=$(echo "$line" | awk -F: '{print $1}')
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    # Skip ubiquitous names (false-positive noise)
    case "$symbol" in
        new|default|clone|drop|from|into|as_ref|as_mut|deref|deref_mut| \
        builder|Self|Error|Result|main|serialize|deserialize)
            continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        # Skip the definer itself (don't count `pub fn foo` as a call to foo).
        if [ "$SKIP_SELF" = "1" ] && [ "$ep" = "$definer_file" ]; then
            : # fallthrough to sibling scan
        elif grep -qw "$symbol" "$ep" 2>/dev/null; then
            found=1; break
        fi
        # Also scan same-crate sibling .rs files (excluding definer if SKIP_SELF=1).
        ep_dir=$(dirname "$ep")
        match=$(find "$ep_dir" -name '*.rs' -type f 2>/dev/null | while IFS= read -r f; do
            if [ "$SKIP_SELF" = "1" ] && [ "$f" = "$definer_file" ]; then
                continue
            fi
            if grep -qw "$symbol" "$f" 2>/dev/null; then
                echo "1"
                break
            fi
        done)
        if [ -n "$match" ]; then
            found=1; break
        fi
    done

    if [ "$found" = "0" ]; then
        echo "$line"
    fi
done < "$TMP_SYMS"
