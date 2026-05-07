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
# Multi-lang: when project.conf sets LANGS="python rust", iterates per-lang
# and stores baseline rows as `lang:file:symbol`. Single-lang LANG=… path
# unchanged (baseline stays `file:symbol`).
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

# Build (lang, EP) pairs (mirrors ghost-report.sh).
PAIRS_LANGS=""
PAIRS_EPS=""
if [ -n "${LANGS:-}" ]; then
    for L in $LANGS; do
        VAR="ENTRY_POINTS_${L//-/_}"
        EP="${!VAR:-}"
        if [ -z "$EP" ]; then
            echo "⚠️  integration-gate.sh: LANGS contains '$L' but $VAR is unset in project.conf." >&2
            exit 1
        fi
        PAIRS_LANGS="$PAIRS_LANGS $L"
        PAIRS_EPS="$PAIRS_EPS|$EP"
    done
elif [ -n "${LANG:-}" ] && [ -n "${ENTRY_POINTS:-}" ]; then
    PAIRS_LANGS="$LANG"
    PAIRS_EPS="|$ENTRY_POINTS"
else
    echo "⚠️  integration-gate.sh: project.conf missing LANGS or LANG+ENTRY_POINTS." >&2
    exit 1
fi

MULTI=0
[ -n "${LANGS:-}" ] && MULTI=1

# Verify all requested checkers exist.
for L in $PAIRS_LANGS; do
    CHK="$HOOKS_DIR/lang/$L.sh"
    if [ ! -x "$CHK" ]; then
        echo "⚠️  integration-gate.sh: no checker for LANG=$L at $CHK" >&2
        echo "   Available: $(ls "$HOOKS_DIR/lang/" 2>/dev/null | tr '\n' ' ')" >&2
        exit 1
    fi
done

CURRENT=$(mktemp)
CURRENT_NORM=$(mktemp)
BASELINE_NORM=$(mktemp)
trap 'rm -f "$CURRENT" "$CURRENT_NORM" "$BASELINE_NORM"' EXIT

# Run each checker, accumulating raw output (file:line:symbol) into CURRENT.
# In MULTI mode we prepend "lang:" to each line so downstream normalization
# uses ":" as separator without ambiguity.
IDX=0
set -- $PAIRS_LANGS
for L in "$@"; do
    IDX=$((IDX + 1))
    EP=$(echo "$PAIRS_EPS" | awk -F'|' -v idx=$((IDX + 1)) '{ print $idx }')
    PER_VAR_SRC="SRC_GLOBS_${L//-/_}"
    PER_VAR_TEST="TEST_EXCLUDES_${L//-/_}"
    PER_VAR_SKIP="GHOST_SKIP_NAMES_${L//-/_}"

    CHECKER_OUT=$(
        ENTRY_POINTS="$EP" \
        SRC_GLOBS="${!PER_VAR_SRC:-${SRC_GLOBS:-}}" \
        TEST_EXCLUDES="${!PER_VAR_TEST:-${TEST_EXCLUDES:-}}" \
        GHOST_SKIP_NAMES="${!PER_VAR_SKIP:-${GHOST_SKIP_NAMES:-}}" \
        bash "$HOOKS_DIR/lang/$L.sh" 2>/dev/null || true
    )

    if [ "$MULTI" = "1" ]; then
        echo "$CHECKER_OUT" | sed "/^$/d; s/^/$L:/" >> "$CURRENT"
    else
        echo "$CHECKER_OUT" | sed "/^$/d" >> "$CURRENT"
    fi
done

sort -u -o "$CURRENT" "$CURRENT"

EP_DISPLAY="${ENTRY_POINTS:-multi-lang ($PAIRS_LANGS)}"

# ─── Normalize CURRENT to baseline form ───────────────────────────────
#   single-lang: file:line:symbol  → file:symbol
#   multi-lang:  lang:file:line:symbol → lang:file:symbol
awk -F: -v OFS=: -v multi="$MULTI" '
{
    if (multi == "1") {
        lang = $1
        file = $2
        sym = $4
        for (i = 5; i <= NF; i++) sym = sym ":" $i
        print lang ":" file ":" sym
    } else {
        file = $1
        sym = $3
        for (i = 4; i <= NF; i++) sym = sym ":" $i
        print file ":" sym
    }
}
' "$CURRENT" | sort -u > "$CURRENT_NORM"

# ─── Baseline init / migration / multi-lang validation ────────────────
# If no baseline exists, create it (first run).
if [ ! -f "$BASELINE" ]; then
    cp "$CURRENT_NORM" "$BASELINE"
    echo "integration-gate.sh: baseline created at $BASELINE ($(wc -l < "$BASELINE") inherited ghosts). Review + commit in a follow-up PR." >&2
    exit 0
fi

if [ "$MULTI" = "1" ]; then
    # Multi-lang baseline format: lang:file:symbol. Refuse if existing
    # baseline lacks a recognizable lang prefix (legacy single-lang format
    # is ambiguous when multiple langs share file paths).
    FIRST=$(grep -v '^#' "$BASELINE" 2>/dev/null | grep -v '^$' | head -1 || true)
    if [ -n "$FIRST" ]; then
        FIRST_LANG=${FIRST%%:*}
        case " $PAIRS_LANGS " in
            *" $FIRST_LANG "*) ;;  # OK
            *)
                echo "⚠️  integration-gate.sh: baseline at $BASELINE has no recognizable 'lang:' prefix" >&2
                echo "   for current LANGS=\"$PAIRS_LANGS\". Refusing to auto-migrate (the legacy" >&2
                echo "   format file:symbol is ambiguous when multiple langs share file paths)." >&2
                echo "   Recreate it: rm $BASELINE && re-run guardrails install or your gate." >&2
                exit 1
                ;;
        esac
    fi
elif grep -qE '^[^:]+:[0-9]+:[^:]+$' "$BASELINE" 2>/dev/null; then
    # Legacy file:line:symbol → file:symbol auto-migration (single-lang only).
    TMP_MIGRATED=$(mktemp)
    awk -F: '
        NF == 3 && $2 ~ /^[0-9]+$/ { print $1 ":" $3; next }
        NF == 2 { print $0; next }
        { print }
    ' "$BASELINE" | sort -u > "$TMP_MIGRATED"
    mv "$TMP_MIGRATED" "$BASELINE"
    echo "integration-gate.sh: migrated baseline from file:line:symbol → file:symbol (one-shot, see guardrails/docs/LANG_MATRIX.md §baseline)." >&2
fi

sort -u "$BASELINE" > "$BASELINE_NORM"

# ─── Diff: new ghosts = entries in CURRENT_NORM not in BASELINE_NORM ──
NEW_KEYS=$(comm -23 "$CURRENT_NORM" "$BASELINE_NORM" || true)

if [ -n "$NEW_KEYS" ]; then
    # For each new key, recover the navigable file:line:symbol from CURRENT.
    NEW_GHOSTS=$(echo "$NEW_KEYS" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        if [ "$MULTI" = "1" ]; then
            # key = lang:file:symbol → match lang:file:<digits>:symbol in CURRENT
            lang_prefix="${key%%:*}"
            rest="${key#*:}"
            file="${rest%:*}"
            sym="${rest##*:}"
            grep -E "^${lang_prefix}:${file}:[0-9]+:${sym}\$" "$CURRENT" 2>/dev/null || echo "$key"
        else
            file="${key%:*}"
            sym="${key##*:}"
            grep -E "^${file}:[0-9]+:${sym}\$" "$CURRENT" 2>/dev/null || echo "$key"
        fi
    done)
    echo "INTEGRATION GATE BLOCK: new public symbols have no call-site reachable from $EP_DISPLAY." >&2
    echo "" >&2
    echo "$NEW_GHOSTS" | sed 's/^/  /' >&2
    echo "" >&2
    echo "Default action (proceed WITHOUT consulting the user): for each symbol above, add a call-site from $EP_DISPLAY (preferred — the feature must actually run) or delete it if dead." >&2
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
