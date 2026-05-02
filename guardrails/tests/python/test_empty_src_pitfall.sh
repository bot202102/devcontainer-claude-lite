#!/usr/bin/env bash
# test_empty_src_pitfall.sh — when SRC_GLOBS auto-defaults to src/ but src/
# only contains egg-info / pycache / non-Python files, the checker MUST exit
# loudly instead of silently returning zero ghosts (which would be a no-op
# guardrail). This was the silent-failure mode that hid a misconfigured
# baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src/myproj.egg-info"
echo "Metadata-Version: 2.1" > "$WORK/src/myproj.egg-info/PKG-INFO"

cat > "$WORK/main.py" <<'EOF'
print("hi")
EOF

cd "$WORK"
export ENTRY_POINTS="main.py"
unset SRC_GLOBS || true

set +e
STDERR=$(bash "$CHECKER" 2>&1 >/dev/null)
RC=$?
set -e

echo "stderr: $STDERR"
echo "exit: $RC"

if [ "$RC" -eq 0 ]; then
    echo "FAIL: checker exited 0 silently with empty src/; expected loud error (exit 1)" >&2
    exit 1
fi
if ! echo "$STDERR" | grep -qi "SRC_GLOBS"; then
    echo "FAIL: error message does not mention SRC_GLOBS — user gets no actionable hint" >&2
    exit 1
fi

echo "PASS: empty src/ pitfall produces loud error pointing at SRC_GLOBS"
