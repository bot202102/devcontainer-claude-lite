#!/usr/bin/env bash
# ghost-report.sh — SessionStart hook. Prints inherited ghost modules at
# session start so Claude sees upfront what's NOT wired to production.
#
# CONTEXT: guardrails/README.md
# CASE STUDY: guardrails/docs/FAKE_WORK_AUDIT.md
#
# Always exits 0. Output goes to stdout and is injected as system-reminder
# into Claude's context at session start.
#
# Multi-lang: when project.conf sets LANGS="python rust", iterates per-lang
# and prefixes each output line with "lang:". Single-lang LANG=… path
# unchanged. See guardrails/docs/LANG_MATRIX.md §Multi-lang projects.

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

# Build (lang, EP) pairs.
# - LANGS set: iterate over each lang, look up ENTRY_POINTS_<lang>.
# - Else LANG + ENTRY_POINTS set: legacy single-lang.
# - Else: silent pass.
PAIRS_LANGS=""
PAIRS_EPS=""
if [ -n "${LANGS:-}" ]; then
    for L in $LANGS; do
        VAR="ENTRY_POINTS_${L//-/_}"
        EP="${!VAR:-}"
        if [ -n "$EP" ]; then
            PAIRS_LANGS="$PAIRS_LANGS $L"
            # Use a record separator (|) between EP groups so we can split later.
            PAIRS_EPS="$PAIRS_EPS|$EP"
        fi
    done
elif [ -n "${LANG:-}" ] && [ -n "${ENTRY_POINTS:-}" ]; then
    PAIRS_LANGS="$LANG"
    PAIRS_EPS="|$ENTRY_POINTS"
else
    exit 0
fi

[ -z "$PAIRS_LANGS" ] && exit 0

MULTI=0
[ -n "${LANGS:-}" ] && MULTI=1

CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT

# Iterate by index over the parallel arrays (PAIRS_LANGS, PAIRS_EPS).
IDX=0
set -- $PAIRS_LANGS
for L in "$@"; do
    IDX=$((IDX + 1))
    EP=$(echo "$PAIRS_EPS" | awk -F'|' -v idx=$((IDX + 1)) '{ print $idx }')
    LANG_CHECKER="$HOOKS_DIR/lang/$L.sh"
    [ -x "$LANG_CHECKER" ] || continue

    # Per-lang overrides fall back to global if not set.
    PER_VAR_SRC="SRC_GLOBS_${L//-/_}"
    PER_VAR_TEST="TEST_EXCLUDES_${L//-/_}"
    PER_VAR_SKIP="GHOST_SKIP_NAMES_${L//-/_}"

    LANG_OUT=$(
        ENTRY_POINTS="$EP" \
        SRC_GLOBS="${!PER_VAR_SRC:-${SRC_GLOBS:-}}" \
        TEST_EXCLUDES="${!PER_VAR_TEST:-${TEST_EXCLUDES:-}}" \
        GHOST_SKIP_NAMES="${!PER_VAR_SKIP:-${GHOST_SKIP_NAMES:-}}" \
        bash "$LANG_CHECKER" 2>/dev/null || true
    )

    if [ "$MULTI" = "1" ]; then
        echo "$LANG_OUT" | sed "/^$/d; s/^/$L:/" >> "$CURRENT"
    else
        echo "$LANG_OUT" | sed "/^$/d" >> "$CURRENT"
    fi
done

sort -u -o "$CURRENT" "$CURRENT"

GHOST_COUNT=$(wc -l < "$CURRENT" | tr -d ' ')

# Representative entry-points string for messaging.
EP_DISPLAY="${ENTRY_POINTS:-multi-lang ($PAIRS_LANGS)}"

if [ "$GHOST_COUNT" -eq 0 ]; then
    echo "Integration gate: 0 ghost symbols — all public symbols have a call-site in $EP_DISPLAY."
    exit 0
fi

echo "Ghost inventory at session start: $GHOST_COUNT public symbols have no call-site in $EP_DISPLAY."
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
echo "Default behaviour for any NEW symbol this session: wire it from $EP_DISPLAY, or delete it."
echo "The Stop gate (.claude/hooks/integration-gate.sh) blocks session end on any new ghost vs baseline."
echo "Do NOT treat .claude/ghost-baseline.txt as a default escape hatch — it is reserved for intentional exceptions that a PR reviewer will validate."
echo "No user confirmation is required to pick wire-vs-delete — decide and proceed."
