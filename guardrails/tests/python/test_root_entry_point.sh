#!/usr/bin/env bash
# test_root_entry_point.sh — regression for the O(N²) hang.
#
# Before this fix: when an entry-point lived at the project root (e.g. main.py),
# `dirname(ep)=.` and the checker did `find . -name '*.py'` for every public
# symbol, hanging indefinitely on workspaces with many files.
#
# After this fix: a single Python pass collects the consumer corpus once.
# This test creates a small fixture (3 modules + root entry-point) and asserts
# the checker finishes in <5 seconds and returns the expected ghosts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a fixture: root entry-point + 1 wired module + 1 ghost module.
mkdir -p "$WORK/pkg"

cat > "$WORK/main.py" <<'EOF'
"""Root entry-point — imports `wired_func` so it is reachable."""
from pkg.wired import wired_func

if __name__ == "__main__":
    wired_func()
EOF

cat > "$WORK/pkg/__init__.py" <<'EOF'
EOF

cat > "$WORK/pkg/wired.py" <<'EOF'
def wired_func():
    """Imported by main.py — should NOT be flagged."""
    return 1
EOF

cat > "$WORK/pkg/ghost.py" <<'EOF'
def lonely_ghost_function():
    """No caller anywhere — MUST be flagged."""
    return 42
EOF

cd "$WORK"
export ENTRY_POINTS="main.py"
export SRC_GLOBS="pkg"

START=$(date +%s)
OUTPUT=$(bash "$CHECKER")
END=$(date +%s)
ELAPSED=$((END - START))

echo "Checker output:"
echo "$OUTPUT"
echo ""
echo "Elapsed: ${ELAPSED}s"

# Assertion 1: must finish in <5s (the hang was indefinite)
if [ "$ELAPSED" -ge 5 ]; then
    echo "FAIL: checker took ${ELAPSED}s, expected <5s (regression of O(N²) hang)" >&2
    exit 1
fi

# Assertion 2: lonely_ghost_function must appear
if ! echo "$OUTPUT" | grep -q "lonely_ghost_function"; then
    echo "FAIL: lonely_ghost_function not flagged as ghost" >&2
    exit 1
fi

# Assertion 3: wired_func must NOT appear (it is imported by entry-point)
if echo "$OUTPUT" | grep -q "wired_func"; then
    echo "FAIL: wired_func flagged as ghost despite being imported by main.py" >&2
    exit 1
fi

echo "PASS: root entry-point handled in ${ELAPSED}s, ghosts/wired classified correctly"
