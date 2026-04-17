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
source "$CONF"

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
    echo "ℹ️  integration-gate.sh: baseline created at $BASELINE ($(wc -l < "$BASELINE") ghosts inherited)." >&2
    echo "   Commit it: git add $BASELINE && git commit -m 'chore: claude integration-gate baseline'" >&2
    exit 0
fi

# Diff current vs baseline. New ghosts = symbols in current NOT in baseline.
NEW_GHOSTS=$(comm -23 "$CURRENT" <(sort -u "$BASELINE") || true)

if [ -n "$NEW_GHOSTS" ]; then
    echo "🚫 INTEGRATION GATE FAILED — new ghost symbols detected." >&2
    echo "" >&2
    echo "The following public symbols were added but have NO call-site" >&2
    echo "reachable from the production entry-point(s): $ENTRY_POINTS" >&2
    echo "" >&2
    echo "$NEW_GHOSTS" | sed 's/^/   /' >&2
    echo "" >&2
    echo "Fix options:" >&2
    echo "  1. (Recommended) Wire the symbol into $ENTRY_POINTS — add the call-site." >&2
    echo "  2. Delete the symbol if it's dead code." >&2
    echo "  3. (Last resort) Add to baseline with a PR-reviewed justification:" >&2
    echo "     echo '<symbol>' >> $BASELINE && git add $BASELINE" >&2
    echo "" >&2
    echo "See guardrails/docs/FAKE_WORK_AUDIT.md for why this gate exists." >&2
    exit 2
fi

# All good. Also report if baseline has ghosts cleared (informational).
CLEARED=$(comm -13 "$CURRENT" <(sort -u "$BASELINE") || true)
if [ -n "$CLEARED" ]; then
    echo "✅ integration-gate.sh: no new ghosts. Cleared from baseline:" >&2
    echo "$CLEARED" | sed 's/^/   /' >&2
    echo "   (consider running: sort -u $CURRENT > $BASELINE && git add $BASELINE)" >&2
fi

exit 0
