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
# Always exits 0 (warning only, never blocks a tool call).
# Reads Claude's tool-call JSON from stdin to extract the edited file path.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOOKS_DIR/project.conf"

[ ! -f "$CONF" ] && exit 0
# shellcheck source=/dev/null
source "$CONF"
[ -z "${LANG:-}" ] && exit 0
[ -z "${ENTRY_POINTS:-}" ] && exit 0

# Parse tool-call input (stdin) to get the file path.
# Claude Code sends a JSON payload like:
#   {"tool_name": "Edit", "tool_input": {"file_path": "/path/to/file.rs", ...}}
INPUT=$(cat || true)
FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"file_path"\s*:\s*"\(.*\)"/\1/' || true)

# If no file path extracted or not a source file, silent pass
[ -z "$FILE_PATH" ] && exit 0

# Only check source files of the configured language
case "$LANG" in
    rust)    case "$FILE_PATH" in *.rs) ;; *) exit 0 ;; esac ;;
    python)  case "$FILE_PATH" in *.py) ;; *) exit 0 ;; esac ;;
    node)    case "$FILE_PATH" in *.ts|*.tsx|*.js|*.jsx) ;; *) exit 0 ;; esac ;;
    go)      case "$FILE_PATH" in *.go) ;; *) exit 0 ;; esac ;;
    java)    case "$FILE_PATH" in *.java) ;; *) exit 0 ;; esac ;;
esac

# Skip test files
case "$FILE_PATH" in
    */tests/*|*_test.*|*.test.*|*_spec.*|*.spec.*|*__test__*)
        exit 0 ;;
esac

# Extract public symbols from the edited file (heuristic — cheap)
case "$LANG" in
    rust)
        SYMBOLS=$(grep -oE '^pub (fn|struct|enum|trait) [A-Za-z_][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $3}' | sort -u || true)
        ;;
    python)
        SYMBOLS=$(grep -oE '^(def|class|async def) [A-Za-z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $2}' | grep -v '^_' | sort -u || true)
        ;;
    node)
        SYMBOLS=$(grep -oE '^export (const|let|var|function|class|async function) [A-Za-z_][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $3}' | sort -u || true)
        ;;
    go)
        SYMBOLS=$(grep -oE '^(func|type|var|const) [A-Z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $2}' | sort -u || true)
        ;;
    java)
        SYMBOLS=$(grep -oE 'public (class|interface|enum) [A-Z][A-Za-z0-9_]*' "$FILE_PATH" 2>/dev/null | awk '{print $3}' | sort -u || true)
        ;;
esac

[ -z "$SYMBOLS" ] && exit 0

# Check each symbol against ENTRY_POINTS
MISSING_SYMBOLS=""
for sym in $SYMBOLS; do
    # Skip common symbol names that are usually trait impls / infrastructure
    case "$sym" in
        new|default|clone|drop|from|into|serialize|deserialize|main|init|__init__|String|Error|Result|Config) continue ;;
    esac

    FOUND=0
    for ep in $ENTRY_POINTS; do
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
    echo "⚠️  new-symbol-guard: $FILE_PATH introduced public symbol(s) with no obvious call-site in $ENTRY_POINTS:"
    for sym in $MISSING_SYMBOLS; do
        echo "   - $sym"
    done
    echo "   Reminder: Definition of Done requires a call-site in the production entry-point before marking 'done'."
    echo "   The Stop hook (integration-gate.sh) will block session end if this becomes a ghost."
fi

exit 0
