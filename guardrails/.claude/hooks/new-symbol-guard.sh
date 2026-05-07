#!/usr/bin/env bash
# new-symbol-guard.sh — PostToolUse hook. Warns (non-blocking) when a file
# edit adds a public symbol without an obvious call-site in ENTRY_POINTS.
#
# CONTEXT: guardrails/README.md
# CASE STUDY: guardrails/docs/FAKE_WORK_AUDIT.md
#
# Unlike integration-gate.sh (which runs at Stop), this runs after every
# Edit/Write. Purpose: feedback loop so Claude can wire immediately, not
# wait until end of turn.
#
# Multi-lang: when project.conf sets LANGS=…, dispatches by file extension
# via lang_for_file() helper. Single-lang LANG=… path unchanged.
#
# Always exits 0 (warning only, never blocks a tool call).
# Reads Claude's tool-call JSON from stdin to extract the edited file path.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOOKS_DIR/project.conf"

[ ! -f "$CONF" ] && exit 0
# shellcheck source=/dev/null
set -a
source "$CONF"
set +a

# Parse tool-call input (stdin) to get the file path.
# Claude Code sends a JSON payload like:
#   {"tool_name": "Edit", "tool_input": {"file_path": "/path/to/file.rs", ...}}
INPUT=$(cat || true)
FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"file_path"\s*:\s*"\(.*\)"/\1/' || true)

# If no file path extracted, silent pass.
[ -z "$FILE_PATH" ] && exit 0

# Helper: file extension → lang name. Empty if no known mapping.
lang_for_file() {
    local f="$1"
    case "$f" in
        *.rs)                  echo "rust" ;;
        *.py)                  echo "python" ;;
        *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
                               echo "node" ;;   # may resolve to nextjs below
        *.go)                  echo "go" ;;
        *.java)                echo "java" ;;
        *.kt)                  echo "kotlin-android" ;;  # may resolve to java below
        *)                     echo "" ;;
    esac
}

# Resolve which lang this edit belongs to.
if [ -n "${LANGS:-}" ]; then
    DETECTED=$(lang_for_file "$FILE_PATH")
    [ -z "$DETECTED" ] && exit 0
    # Resolve overlapping pairs: nextjs accepts node's extensions; java accepts kotlin's.
    case " $LANGS " in
        *" nextjs "*)         [ "$DETECTED" = "node" ] && DETECTED="nextjs" ;;
    esac
    case " $LANGS " in
        *" java "*)           [ "$DETECTED" = "kotlin-android" ] && DETECTED="java" ;;
    esac
    case " $LANGS " in
        *" $DETECTED "*) ;;
        *) exit 0 ;;
    esac
    EFF_LANG="$DETECTED"
    EP_VAR="ENTRY_POINTS_${EFF_LANG//-/_}"
    EFF_EP="${!EP_VAR:-}"
    [ -z "$EFF_EP" ] && exit 0
elif [ -n "${LANG:-}" ] && [ -n "${ENTRY_POINTS:-}" ]; then
    EFF_LANG="$LANG"
    EFF_EP="$ENTRY_POINTS"
else
    exit 0
fi

# Filter by extension for the resolved lang.
case "$EFF_LANG" in
    rust)            case "$FILE_PATH" in *.rs) ;; *) exit 0 ;; esac ;;
    python)          case "$FILE_PATH" in *.py) ;; *) exit 0 ;; esac ;;
    node|nextjs)     case "$FILE_PATH" in *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) ;; *) exit 0 ;; esac ;;
    go)              case "$FILE_PATH" in *.go) ;; *) exit 0 ;; esac ;;
    java)            case "$FILE_PATH" in *.java|*.kt) ;; *) exit 0 ;; esac ;;
    kotlin-android)  case "$FILE_PATH" in *.kt) ;; *) exit 0 ;; esac ;;
esac

# Skip test files
case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*_spec.*|*.spec.*|*__test__*|*/src/test/*|*/src/androidTest/*|*TestKoin.kt|*Test.kt|*Tests.kt|*Spec.kt)
        exit 0 ;;
esac

# Extract public symbols from the edited file (heuristic — cheap)
case "$EFF_LANG" in
    rust)
        SYMBOLS=$(grep -oE '^pub (fn|struct|enum|trait) [A-Za-z_][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $3}' | sort -u || true)
        ;;
    python)
        SYMBOLS=$(grep -oE '^(def|class|async def) [A-Za-z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $2}' | grep -v '^_' | sort -u || true)
        ;;
    node|nextjs)
        SYMBOLS=$(grep -oE '^export (const|let|var|function|class|async function) [A-Za-z_][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $3}' | sort -u || true)
        ;;
    go)
        SYMBOLS=$(grep -oE '^(func|type|var|const) [A-Z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $2}' | sort -u || true)
        ;;
    java)
        SYMBOLS=$(grep -oE 'public (class|interface|enum) [A-Z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $3}' | sort -u || true)
        ;;
    kotlin-android)
        # Kotlin: classes are public by default — reject explicit private/internal/protected.
        # Match column-0 declarations only (skip inner / member decls).
        # Class-like:  (data|sealed|abstract|open|inline|value|annotation|enum)? (class|object|interface) Name
        # Top-level fun (column 0).
        CLASSES=$(grep -E '^(public[[:space:]]+)?(abstract[[:space:]]+|open[[:space:]]+|final[[:space:]]+|sealed[[:space:]]+|data[[:space:]]+|inline[[:space:]]+|value[[:space:]]+|annotation[[:space:]]+|enum[[:space:]]+)*(class|object|interface)[[:space:]]+[A-Z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | \
            grep -vE '^[[:space:]]*(private|internal|protected)' | \
            sed -E 's/^(public[[:space:]]+)?(abstract[[:space:]]+|open[[:space:]]+|final[[:space:]]+|sealed[[:space:]]+|data[[:space:]]+|inline[[:space:]]+|value[[:space:]]+|annotation[[:space:]]+|enum[[:space:]]+)*(class|object|interface)[[:space:]]+([A-Z][A-Za-z0-9_]*).*/\4/' | sort -u || true)
        FUNCS=$(grep -E '^fun[[:space:]]+[a-zA-Z_][A-Za-z0-9_]*[[:space:]]*\(' "$FILE_PATH" 2>/dev/null | \
            sed -E 's/^fun[[:space:]]+([a-zA-Z_][A-Za-z0-9_]*).*/\1/' | sort -u || true)
        SYMBOLS=$(printf '%s\n%s\n' "$CLASSES" "$FUNCS" | grep -v '^$' | sort -u || true)
        ;;
esac

[ -z "$SYMBOLS" ] && exit 0

# Check each symbol against the resolved entry-points.
MISSING_SYMBOLS=""
for sym in $SYMBOLS; do
    # Skip common symbol names that are usually trait impls / infrastructure
    case "$sym" in
        new|default|clone|drop|from|into|serialize|deserialize|main|init|__init__|String|Error|Result|Config) continue ;;
        # kotlin-android infrastructure / framework-managed names
        Companion|invoke|Color|Theme|Type|Typography|Shapes|R|BuildConfig) continue ;;
    esac

    FOUND=0
    for ep in $EFF_EP; do
        if [ -f "$ep" ] && grep -q "\b$sym\b" "$ep" 2>/dev/null; then
            FOUND=1
            break
        fi
    done

    if [ $FOUND -eq 0 ]; then
        MISSING_SYMBOLS="$MISSING_SYMBOLS $sym"
    fi
done

MISSING_SYMBOLS=$(echo "$MISSING_SYMBOLS" | tr -s ' ')

if [ -n "$MISSING_SYMBOLS" ]; then
    # Warning only — non-blocking (exit 0). Claude sees this as context.
    echo ""
    echo "⚠️  new-symbol-guard: $FILE_PATH introduced public symbol(s) with no obvious call-site in $EFF_EP:"
    for sym in $MISSING_SYMBOLS; do
        echo "   - $sym"
    done
    echo "   Reminder: Definition of Done requires a call-site in the production entry-point before marking 'done'."
    echo "   The Stop hook (integration-gate.sh) will block session end if this becomes a ghost."
fi

exit 0
