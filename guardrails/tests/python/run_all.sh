#!/usr/bin/env bash
# run_all.sh — run every python.sh regression test in this directory.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$SCRIPT_DIR"/*.sh
FAIL=0
for t in "$SCRIPT_DIR"/test_*.sh; do
    echo ""
    echo "═══ $(basename "$t") ═══"
    if bash "$t"; then
        :
    else
        FAIL=$((FAIL + 1))
    fi
done
echo ""
if [ $FAIL -gt 0 ]; then
    echo "❌ $FAIL test(s) failed"
    exit 1
fi
echo "✅ all python.sh regression tests passed"
