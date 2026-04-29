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
set -a
source "$CONF"
set +a

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
    echo "Integration gate: 0 ghost symbols — all public symbols have a call-site in $ENTRY_POINTS."
    exit 0
fi

echo "Ghost inventory at session start: $GHOST_COUNT public symbols have no call-site in $ENTRY_POINTS."
echo "These compile (and may have passing tests) but are never invoked from production code."
echo ""

# Top 5 directories by ghost count — helps Claude triage which subsystems
# carry the most fake-work debt. Uses the first 4 path segments as the
# bucket so monorepos (apps/web/src/...) get useful granularity.
if [ "$GHOST_COUNT" -gt 10 ]; then
    echo "  Top directories by ghost count:"
    awk -F: '{
        n = split($1, parts, "/")
        bucket = parts[1]
        for (i = 2; i <= n - 1 && i <= 4; i++) bucket = bucket "/" parts[i]
        print bucket
    }' "$CURRENT" | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
    echo ""
fi

head -20 "$CURRENT" | sed 's/^/  /'
if [ "$GHOST_COUNT" -gt 20 ]; then
    echo "  ... and $((GHOST_COUNT - 20)) more"
fi

echo ""
echo "Default behaviour for any NEW symbol this session: wire it from $ENTRY_POINTS, or delete it."
echo "The Stop gate (.claude/hooks/integration-gate.sh) blocks session end on any new ghost vs baseline."
echo "Do NOT treat .claude/ghost-baseline.txt as a default escape hatch — it is reserved for intentional exceptions that a PR reviewer will validate."
echo "No user confirmation is required to pick wire-vs-delete — decide and proceed."
