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
CURRENT_NORM=$(mktemp)
BASELINE_NORM=$(mktemp)
trap 'rm -f "$CURRENT" "$CURRENT_NORM" "$BASELINE_NORM"' EXIT

bash "$LANG_CHECKER" | sort -u > "$CURRENT" || true

# ─── Baseline format: `file:symbol` (symbol-based, line-independent) ──
#
# Rationale: the previous format `file:line:symbol` was brittle — adding
# an `import` at the top of a file shifted every subsequent line number
# and produced N bogus "new ghost" alerts even when the symbols were
# unchanged. The new format keys ghosts by file+symbol identity, so
# line shifts are invisible to the diff.
#
# Output to the user still shows `file:line:symbol` — we keep the line
# for navigation. Only the BASELINE stores the line-independent form.

# Normalize CURRENT (file:line:symbol) to file:symbol (drop middle field).
# Robust to rare colons in symbol names via awk OFS reconstruction.
awk -F: -v OFS=: '{
    # Join fields 1 (file) and the rest-after-field-2 (symbol, which may
    # itself contain colons in pathological cases).
    file = $1
    sym = $3
    for (i = 4; i <= NF; i++) sym = sym ":" $i
    print file ":" sym
}' "$CURRENT" | sort -u > "$CURRENT_NORM"

# If no baseline exists, create it (first run) in the new symbol-based format.
if [ ! -f "$BASELINE" ]; then
    cp "$CURRENT_NORM" "$BASELINE"
    echo "integration-gate.sh: baseline created at $BASELINE ($(wc -l < "$BASELINE") inherited ghosts, symbol-based). Review + commit in a follow-up PR." >&2
    exit 0
fi

# ─── Auto-migrate legacy baseline (file:line:symbol → file:symbol) ────
# Detect format: lines with exactly 2 colons (`path:123:Name`) are legacy.
# We tolerate a mixed file too (some already migrated), migrating only the
# legacy rows on the fly.
if grep -qE '^[^:]+:[0-9]+:[^:]+$' "$BASELINE" 2>/dev/null; then
    TMP_MIGRATED=$(mktemp)
    awk -F: '
        # Legacy row: file:line:symbol  (3 fields, field 2 is digits)
        NF == 3 && $2 ~ /^[0-9]+$/ { print $1 ":" $3; next }
        # Already migrated: file:symbol  (2 fields)
        NF == 2 { print $0; next }
        # Other rows: keep verbatim (comments, blank lines)
        { print }
    ' "$BASELINE" | sort -u > "$TMP_MIGRATED"
    mv "$TMP_MIGRATED" "$BASELINE"
    echo "integration-gate.sh: migrated baseline from file:line:symbol → file:symbol (one-shot, see guardrails/docs/LANG_MATRIX.md §baseline)." >&2
fi

sort -u "$BASELINE" > "$BASELINE_NORM"

# ─── Diff: new ghosts = entries in CURRENT_NORM not in BASELINE_NORM ──
NEW_KEYS=$(comm -23 "$CURRENT_NORM" "$BASELINE_NORM" || true)

if [ -n "$NEW_KEYS" ]; then
    # For each new key `file:symbol`, recover its `file:line:symbol` from
    # CURRENT so the user sees a navigable reference.
    NEW_GHOSTS=$(echo "$NEW_KEYS" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        file="${key%:*}"
        sym="${key##*:}"
        # Match `file:<digits>:<sym>` in CURRENT
        grep -E "^${file}:[0-9]+:${sym}\$" "$CURRENT" 2>/dev/null || echo "$key"
    done)
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
CLEARED=$(comm -13 "$CURRENT_NORM" "$BASELINE_NORM" || true)
if [ -n "$CLEARED" ]; then
    echo "integration-gate.sh: no new ghosts. Symbols no longer in the scan that baseline still lists:" >&2
    echo "$CLEARED" | sed 's/^/  /' >&2
    echo "A baseline refresh (sort -u $CURRENT_NORM > $BASELINE) is appropriate when convenient; it is not blocking." >&2
fi

exit 0
