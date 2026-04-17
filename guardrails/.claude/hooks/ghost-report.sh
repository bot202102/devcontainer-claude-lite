#!/usr/bin/env bash
# ghost-report.sh — SessionStart hook. Prints inherited ghost modules at
# session start so Claude sees upfront what's NOT wired to production.
#
# CONTEXT: guardrails/README.md
# CASE STUDY: guardrails/docs/FAKE_WORK_AUDIT.md
#
# Always exits 0. Output goes to stdout and is injected as system-reminder
# into Claude's context at session start.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOOKS_DIR/project.conf"
BASELINE="$HOOKS_DIR/../ghost-baseline.txt"

# No config? Silent pass (don't spam fresh repos)
if [ ! -f "$CONF" ]; then
    exit 0
fi

# shellcheck source=/dev/null
source "$CONF"

if [ -z "${LANG:-}" ] || [ -z "${ENTRY_POINTS:-}" ]; then
    exit 0
fi

LANG_CHECKER="$HOOKS_DIR/lang/$LANG.sh"
if [ ! -x "$LANG_CHECKER" ]; then
    exit 0
fi

# Run the lang-specific check
CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT

bash "$LANG_CHECKER" | sort -u > "$CURRENT" || true

GHOST_COUNT=$(wc -l < "$CURRENT" | tr -d ' ')

if [ "$GHOST_COUNT" -eq 0 ]; then
    echo "✅ Integration gate: 0 ghost modules (all public symbols wired to $ENTRY_POINTS)."
    exit 0
fi

echo "👻 GHOST MODULES DETECTED at session start ($GHOST_COUNT public symbols without call-site in production entry-point):"
echo ""

# Show up to 20, then summary
head -20 "$CURRENT" | sed 's/^/   /'

if [ "$GHOST_COUNT" -gt 20 ]; then
    echo "   ... and $((GHOST_COUNT - 20)) more"
fi

echo ""
echo "Entry-point: $ENTRY_POINTS"
echo "These symbols compile and may have tests, but are NOT invoked from production code."
echo ""
echo "Action needed (choose one before closing session):"
echo "  - Wire into $ENTRY_POINTS (preferred — the feature should actually run)"
echo "  - Delete if dead code"
echo "  - Add to baseline (.claude/ghost-baseline.txt) with PR-reviewable justification"
echo ""
echo "Stop hook (.claude/hooks/integration-gate.sh) will block session end if"
echo "new ghosts appear vs baseline. See guardrails/docs/FAKE_WORK_AUDIT.md."
