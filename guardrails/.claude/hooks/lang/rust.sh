#!/usr/bin/env bash
# rust.sh — extract public symbols without call-site in ENTRY_POINTS.
#
# Contract: see guardrails/docs/LANG_MATRIX.md
# Invoked by: integration-gate.sh, ghost-report.sh
#
# Output (stdout): one ghost per line, format "<file:line>:<symbol>"
# Input: env vars ENTRY_POINTS, SRC_GLOBS (optional), TEST_EXCLUDES (optional)

set -euo pipefail

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"

if ! command -v rg >/dev/null 2>&1; then
    echo "rust.sh: ripgrep (rg) required but not found" >&2
    exit 0
fi

# Default source glob for typical Rust workspaces
if [ -z "$SRC_GLOBS" ]; then
    if [ -d "crates" ]; then
        SCAN_ARGS=(crates)
    elif [ -d "src" ]; then
        SCAN_ARGS=(src)
    else
        SCAN_ARGS=(.)
    fi
else
    # shellcheck disable=SC2206
    SCAN_ARGS=($SRC_GLOBS)
fi

# Build exclude args: default + user overrides
EXCLUDES=(
    --glob '!**/tests/**'
    --glob '!**/*_test.rs'
    --glob '!**/test_*.rs'
    --glob '!**/benches/**'
    --glob '!**/examples/**'
    --glob '!**/target/**'
)
for extra in $TEST_EXCLUDES; do
    EXCLUDES+=(--glob "!$extra")
done

# Extract public symbol definitions (outside #[cfg(test)] blocks — heuristic:
# we exclude entire test files; symbols inside `mod tests { ... }` within non-test
# files are harder to exclude without an AST but grep on raw `pub fn` in test
# modules is a low-noise false-positive in practice)
SYMBOLS=$(rg -t rust "${EXCLUDES[@]}" \
    -n --no-heading --with-filename \
    '^(pub )?(fn|struct|enum|trait)\s+([A-Za-z_][A-Za-z0-9_]*)' \
    "${SCAN_ARGS[@]}" 2>/dev/null | \
    grep 'pub ' | \
    sed -E 's|^([^:]+):([0-9]+):.*(fn|struct|enum|trait)\s+([A-Za-z_][A-Za-z0-9_]*).*|\1:\2:\4|' || true)

[ -z "$SYMBOLS" ] && exit 0

# For each symbol, check if it appears in ENTRY_POINTS
while IFS= read -r line; do
    [ -z "$line" ] && continue
    symbol=$(echo "$line" | awk -F: '{print $NF}')

    # Skip ubiquitous names that would be false-positives
    case "$symbol" in
        new|default|clone|drop|from|into|as_ref|as_mut|deref|deref_mut|builder|Self|Error|Result|main) continue ;;
    esac

    found=0
    for ep in $ENTRY_POINTS; do
        [ ! -f "$ep" ] && continue
        # Check if the symbol is referenced in entry-point (or transitively via module tree)
        # Heuristic: grep entry-point + same-crate sibling files. Full call-graph would need cargo tree.
        ep_dir=$(dirname "$ep")
        if rg -q "\b$symbol\b" "$ep" 2>/dev/null; then
            found=1; break
        fi
        # Also check sibling modules in the same crate (mod.rs, lib.rs)
        if rg -q "\b$symbol\b" "$ep_dir" --type rust 2>/dev/null; then
            found=1; break
        fi
    done

    if [ $found -eq 0 ]; then
        echo "$line"
    fi
done <<< "$SYMBOLS"
