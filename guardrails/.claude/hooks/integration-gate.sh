#!/usr/bin/env bash
# integration-gate.sh — Stop hook. Blocks session end if new ghost symbols
# appeared (public symbols without a call-site in the production entry-point).
#
# CONTEXT: guardrails/README.md
# CASE STUDY: guardrails/docs/FAKE_WORK_AUDIT.md
#
# Exit codes:
#   0 — no ghosts, or ghosts unchanged vs baseline (session end allowed)
#   1 — setup error (bad config, missing lang checker) — warns, does not block
#   2 — new ghosts detected — blocks Stop, Claude receives stderr as feedback
#
# DO NOT modify this script to always `exit 0`. The `exit 2` is the point.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOOKS_DIR/project.conf"
BASELINE="$HOOKS_DIR/../ghost-baseline.txt"

if [ ! -f "$CONF" ]; then
    echo "⚠️  integration-gate.sh: .claude/hooks/project.conf not found." >&2
    echo "   Run: cp $HOOKS_DIR/project.conf.example $CONF && edit it." >&2
    exit 1
fi

# shellcheck source=/dev/null
set -a
source "$CONF"
set +a

if [ -z "${LANG:-}" ] || [ -z "${ENTRY_POINTS:-}" ]; then
    echo "⚠️  integration-gate.sh: project.conf missing LANG or ENTRY_POINTS." >&2
    exit 1
fi

LANG_CHECKER="$HOOKS_DIR/lang/$LANG.sh"
if [ ! -x "$LANG_CHECKER" ]; then
    echo "⚠️  integration-gate.sh: no checker for LANG=$LANG at $LANG_CHECKER" >&2
    echo "   Available: $(ls "$HOOKS_DIR/lang/" 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
fi

CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT

bash "$LANG_CHECKER" | sort -u > "$CURRENT" || true

# If no baseline exists, create it (first run) and pass.
if [ ! -f "$BASELINE" ]; then
    cp "$CURRENT" "$BASELINE"
    echo "integration-gate.sh: baseline created at $BASELINE ($(wc -l < "$BASELINE") inherited ghosts). Review + commit in a follow-up PR." >&2
    exit 0
fi

# Diff current vs baseline. New ghosts = symbols in current NOT in baseline.
NEW_GHOSTS=$(comm -23 "$CURRENT" <(sort -u "$BASELINE") || true)

if [ -n "$NEW_GHOSTS" ]; then
    echo "INTEGRATION GATE BLOCK: new public symbols have no call-site reachable from $ENTRY_POINTS." >&2
    echo "" >&2
    echo "$NEW_GHOSTS" | sed 's/^/  /' >&2
    echo "" >&2
    echo "Default action (proceed WITHOUT consulting the user): for each symbol above, add a call-site from $ENTRY_POINTS (preferred — the feature must actually run) or delete it if dead." >&2
    echo "Appending to $BASELINE is a last-resort escape hatch reserved for intentional exceptions that a PR reviewer will validate; do not use it to close this turn quickly." >&2
    echo "Context: guardrails/docs/FAKE_WORK_AUDIT.md." >&2
    exit 2
fi

# All good. Informational: if ghosts cleared from baseline, suggest a refresh.
CLEARED=$(comm -13 "$CURRENT" <(sort -u "$BASELINE") || true)
if [ -n "$CLEARED" ]; then
    echo "integration-gate.sh: no new ghosts. Symbols no longer in the scan that baseline still lists:" >&2
    echo "$CLEARED" | sed 's/^/  /' >&2
    echo "A baseline refresh (sort -u $CURRENT > $BASELINE) is appropriate when convenient; it is not blocking." >&2
fi

exit 0
