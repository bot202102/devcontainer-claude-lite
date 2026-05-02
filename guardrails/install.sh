#!/usr/bin/env bash
# install.sh — universal installer for the integration-gates guardrails.
#
# Usage: bash guardrails/install.sh <target-project-dir> <lang>
#
# Copies .claude/ contents into <target-project-dir>/.claude/, writes a
# project.conf with the specified lang, initializes ghost-baseline.txt,
# and appends the Definition of Done to <target>/CLAUDE.md.
#
# langs: rust | python | node | astro | nextjs | go | java | kotlin-android
#
# `astro` is a specialization of `node` for Astro projects: it treats every
# file under src/pages/ plus src/middleware.ts and astro.config.{mjs,ts,js}
# as an implicit entry-point (file-based routing has no single `main`).
#
# `kotlin-android` is a specialization for Android Kotlin projects: it
# treats your Application class + MainActivity + top-level NavGraph as
# multi-entry-points, auto-discovers Koin module DSL files (`module {`)
# as additional reachability sources, and consults AndroidManifest.xml for
# manifest-declared Service / Receiver / Provider symbols. Use this for
# Android-specific projects; for server-side or KMP Kotlin without
# Android conventions, the `java` checker (which scans .kt + .java) or a
# new `kotlin` checker is more appropriate.
#
# Idempotent-ish: re-running overwrites hook scripts (so updates propagate)
# but preserves project.conf and ghost-baseline.txt if they exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
LANG="${2:-}"

if [ -z "$TARGET" ] || [ -z "$LANG" ]; then
    echo "Usage: $0 <target-project-dir> <lang>" >&2
    echo "  langs: rust | python | node | astro | nextjs | go | java | kotlin-android" >&2
    exit 1
fi

if [ ! -d "$TARGET" ]; then
    echo "Target directory does not exist: $TARGET" >&2
    exit 1
fi

case "$LANG" in
    rust|python|node|astro|nextjs|go|java|kotlin-android) ;;
    *)
        echo "Unsupported language: $LANG" >&2
        echo "Supported: rust | python | node | astro | nextjs | go | java | kotlin-android" >&2
        exit 1
        ;;
esac

cd "$TARGET"

echo "→ Installing integration-gates guardrails into $TARGET (lang=$LANG)"
echo ""

# 1. Copy .claude/ structure
mkdir -p .claude/hooks/lang
cp -f "$SCRIPT_DIR/.claude/hooks/integration-gate.sh" .claude/hooks/
cp -f "$SCRIPT_DIR/.claude/hooks/ghost-report.sh" .claude/hooks/
cp -f "$SCRIPT_DIR/.claude/hooks/new-symbol-guard.sh" .claude/hooks/
cp -f "$SCRIPT_DIR/.claude/hooks/lang/$LANG.sh" .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

echo "  ✓ Copied hook scripts to .claude/hooks/"

# 2. Merge or create settings.json
if [ -f ".claude/settings.json" ]; then
    echo "  ⚠️  .claude/settings.json already exists — NOT overwriting."
    echo "     Merge the hooks section from $SCRIPT_DIR/.claude/settings.json manually."
else
    cp -f "$SCRIPT_DIR/.claude/settings.json" .claude/settings.json
    echo "  ✓ Created .claude/settings.json with hooks registered"
fi

# 3. Create project.conf if missing
if [ ! -f ".claude/hooks/project.conf" ]; then
    # Detect entry-point heuristically by language
    case "$LANG" in
        rust)
            if [ -f "src/main.rs" ]; then EP="src/main.rs"
            elif ls crates/*/src/main.rs 2>/dev/null | head -1; then EP=$(ls crates/*/src/main.rs 2>/dev/null | head -1)
            else EP="src/main.rs"
            fi
            ;;
        python)
            if [ -f "src/__main__.py" ]; then EP="src/__main__.py"
            elif ls src/*/__main__.py 2>/dev/null | head -1; then EP=$(ls src/*/__main__.py 2>/dev/null | head -1)
            elif [ -f "main.py" ]; then EP="main.py"
            else EP="src/__main__.py"
            fi
            ;;
        node)
            # Read "main" from package.json if present
            if [ -f "package.json" ] && command -v node >/dev/null 2>&1; then
                EP=$(node -e "try { console.log(require('./package.json').main || 'src/index.ts') } catch(e) { console.log('src/index.ts') }" 2>/dev/null)
            else
                EP="src/index.ts"
            fi
            ;;
        astro)
            # Astro has no single entry-point. We record a representative
            # root that the gate messages can refer to; the checker itself
            # auto-discovers src/pages/** + middleware + astro.config.
            if [ -d "src/pages" ]; then EP="src/pages/"
            else EP="src/pages/"
            fi
            ;;
        nextjs)
            # Next.js App Router has no single entry-point. We record a
            # representative root for messages; the checker auto-discovers
            # src/app/** (and src/pages/** if present) + middleware +
            # next.config.* + instrumentation.
            if [ -d "src/app" ]; then EP="src/app/"
            elif [ -d "app" ]; then EP="app/"
            elif [ -d "src/pages" ]; then EP="src/pages/"
            elif [ -d "pages" ]; then EP="pages/"
            else EP="src/app/"
            fi
            ;;
        go)
            if ls cmd/*/main.go 2>/dev/null | head -1; then EP=$(ls cmd/*/main.go 2>/dev/null | head -1)
            elif [ -f "main.go" ]; then EP="main.go"
            else EP="cmd/app/main.go"
            fi
            ;;
        java)
            EP=$(find src/main/java -name '*.java' -exec grep -l 'public static void main' {} \; 2>/dev/null | head -1)
            EP="${EP:-src/main/java/App.java}"
            ;;
        kotlin-android)
            # Android entry-points: MainActivity + Application class + top-level
            # Compose graph composable. Auto-discover MainActivity; the user
            # should review and add their Application class + nav graph file.
            MAIN_ACTIVITY=$(find app/src/main/java -name 'MainActivity.kt' 2>/dev/null | head -1)
            APP_CLASS=$(find app/src/main/java -name '*Application.kt' 2>/dev/null | head -1)
            APP_GRAPH=$(find app/src/main/java -name '*App.kt' -not -name '*Application.kt' 2>/dev/null | head -1)
            EP="${MAIN_ACTIVITY:-app/src/main/java/MainActivity.kt}"
            [ -n "$APP_CLASS" ] && EP="$EP $APP_CLASS"
            [ -n "$APP_GRAPH" ] && EP="$EP $APP_GRAPH"
            ;;
    esac

    cat > .claude/hooks/project.conf <<EOF
# Auto-generated by guardrails/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# See guardrails/docs/LANG_MATRIX.md for full reference.

LANG="$LANG"
ENTRY_POINTS="$EP"
EOF
    echo "  ✓ Created .claude/hooks/project.conf (LANG=$LANG, ENTRY_POINTS=$EP)"
    echo "     Verify the entry-point is correct. Edit if needed:"
    echo "       \$EDITOR .claude/hooks/project.conf"
else
    echo "  ⚠️  .claude/hooks/project.conf already exists — NOT overwriting."
fi

# 4. Initialize ghost baseline
if [ ! -f ".claude/ghost-baseline.txt" ]; then
    # shellcheck source=/dev/null
    source .claude/hooks/project.conf
    bash ".claude/hooks/lang/$LANG.sh" 2>/dev/null | sort -u > .claude/ghost-baseline.txt || true
    GHOST_COUNT=$(wc -l < .claude/ghost-baseline.txt | tr -d ' ')
    echo "  ✓ Captured ghost baseline ($GHOST_COUNT inherited symbols) at .claude/ghost-baseline.txt"
    if [ "$GHOST_COUNT" -gt 0 ]; then
        echo "     These symbols are accepted as-is. Review in PR to wire or delete over time."
    fi
else
    echo "  ⚠️  .claude/ghost-baseline.txt already exists — NOT overwriting."
fi

# 5. Append Definition of Done to CLAUDE.md
DOD_MARKER="## Definition of Done (no negociable)"
if [ -f "CLAUDE.md" ] && grep -q "$DOD_MARKER" CLAUDE.md; then
    echo "  ⚠️  CLAUDE.md already has Definition of Done — NOT appending."
else
    if [ ! -f "CLAUDE.md" ]; then
        echo "# CLAUDE.md" > CLAUDE.md
        echo "" >> CLAUDE.md
        echo "  ✓ Created CLAUDE.md"
    fi
    # Extract the block between begin/end markers from DoD source
    sed -n '/<!-- begin/,/<!-- end/p' "$SCRIPT_DIR/docs/DEFINITION_OF_DONE.md" | \
        sed '1d;$d' >> CLAUDE.md
    echo "  ✓ Appended Definition of Done to CLAUDE.md"
fi

# 6. Install the verify-done skill (declarative-with-evidence layer).
#    Complements the mechanical hooks by letting the agent self-audit with
#    real command output before claiming completion. See guardrails/skills/verify-done.md.
if [ -f "$SCRIPT_DIR/skills/verify-done.md" ]; then
    mkdir -p .claude/skills
    if [ -f ".claude/skills/verify-done.md" ]; then
        echo "  ⚠️  .claude/skills/verify-done.md already exists — NOT overwriting."
    else
        cp -f "$SCRIPT_DIR/skills/verify-done.md" .claude/skills/verify-done.md
        echo "  ✓ Installed verify-done skill at .claude/skills/verify-done.md"
    fi
fi

echo ""
echo "✅ Installation complete."
echo ""
echo "Next steps:"
echo "  1. Verify .claude/hooks/project.conf (especially ENTRY_POINTS)"
echo "  2. git add .claude/ CLAUDE.md && git commit -m 'chore: integration gates'"
echo "  3. Restart Claude Code — SessionStart hook will report current ghost count"
echo ""
echo "Docs:"
echo "  - Problem + approach: guardrails/README.md"
echo "  - Real case study:    guardrails/docs/FAKE_WORK_AUDIT.md"
echo "  - Per-lang mechanism: guardrails/docs/LANG_MATRIX.md"
echo "  - Self-check skill:   guardrails/skills/verify-done.md (installed at .claude/skills/)"
