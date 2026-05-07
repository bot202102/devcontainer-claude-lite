#!/usr/bin/env bash
# test_python_only_unaffected.sh — single-lang LANG=python projects must
# behave exactly as they did pre-#27 (regresión 0).
#
# Asserts: integration-gate.sh on a clean single-lang Python project
# creates the baseline in 2-field file:symbol format (no lang prefix)
# and reports zero new ghosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture: 1 entry-point + 1 wired module + 1 ghost.
mkdir -p "$WORK/src/pkg"
cat > "$WORK/src/main.py" <<'EOF'
from pkg.wired import wired_func
if __name__ == "__main__":
    wired_func()
EOF
touch "$WORK/src/pkg/__init__.py"
cat > "$WORK/src/pkg/wired.py" <<'EOF'
def wired_func():
    return 1
EOF
cat > "$WORK/src/pkg/ghost.py" <<'EOF'
def lonely_ghost():
    return 42
EOF

cd "$WORK"
mkdir -p .claude/hooks/lang
cp "$GUARDRAILS_ROOT/.claude/hooks/integration-gate.sh" .claude/hooks/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"      .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

cat > .claude/hooks/project.conf <<EOF
LANG="python"
ENTRY_POINTS="src/main.py"
SRC_GLOBS="src"
EOF

# First run: creates baseline. exit 0 expected.
set +e
bash .claude/hooks/integration-gate.sh
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: first run should exit 0 (creates baseline). Got $RC" >&2
    exit 1
fi

if [ ! -f .claude/ghost-baseline.txt ]; then
    echo "FAIL: baseline not created" >&2
    exit 1
fi

# Negative: no 'python:' prefix anywhere (would mean multi-lang format leaked into single-lang).
if grep -qE '^python:' .claude/ghost-baseline.txt; then
    echo "FAIL: single-lang baseline has 'python:' prefix (regression — should be file:symbol)" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

# Positive: every row must be exactly 2 colon-separated fields (file:symbol).
# Catches regression to legacy 3-field 'file:line:symbol' format.
if ! awk -F: 'NF != 2 { exit 1 }' .claude/ghost-baseline.txt; then
    echo "FAIL: baseline rows are not exactly 2 fields (file:symbol). Likely regression to file:line:symbol legacy format." >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

# Cardinality: fixture defines exactly one ghost (lonely_ghost in pkg/ghost.py).
LINE_COUNT=$(wc -l < .claude/ghost-baseline.txt | tr -d ' ')
if [ "$LINE_COUNT" != "1" ]; then
    echo "FAIL: expected exactly 1 baseline row (fixture has 1 ghost), got $LINE_COUNT" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

if ! grep -q "lonely_ghost" .claude/ghost-baseline.txt; then
    echo "FAIL: ghost 'lonely_ghost' not captured in baseline" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

# Second run: zero new ghosts. exit 0.
set +e
bash .claude/hooks/integration-gate.sh
RC2=$?
set -e
if [ $RC2 -ne 0 ]; then
    echo "FAIL: second run with unchanged code should exit 0. Got $RC2" >&2
    exit 1
fi

echo "PASS: single-lang LANG=python behavior unchanged (no lang prefix, baseline file:symbol)"
