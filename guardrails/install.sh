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
    echo "  langs: rust | python | node | astro | nextjs | go | java | kotlin-android | python-rust" >&2
    exit 1
fi

if [ ! -d "$TARGET" ]; then
    echo "Target directory does not exist: $TARGET" >&2
    exit 1
fi

case "$LANG" in
    rust|python|node|astro|nextjs|go|java|kotlin-android) ;;
    python-rust) ;;  # meta-lang: installs both python.sh + rust.sh
    *)
        echo "Unsupported language: $LANG" >&2
        echo "Supported: rust | python | node | astro | nextjs | go | java | kotlin-android | python-rust" >&2
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
if [ "$LANG" = "python-rust" ]; then
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/python.sh" .claude/hooks/lang/
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/rust.sh" .claude/hooks/lang/
else
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/$LANG.sh" .claude/hooks/lang/
fi
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
        python-rust)
            # Heuristic: prefer python/<pkg>/cli.py, then python/main.py, then main.py.
            EP_PY=""
            for cand in $(ls python/*/cli.py 2>/dev/null) python/main.py main.py src/__main__.py; do
                if [ -f "$cand" ]; then EP_PY="$cand"; break; fi
            done
            EP_PY="${EP_PY:-python/main.py}"

            # Heuristic: prefer rust/crates/*/src/main.rs, then rust/src/main.rs, then src/main.rs.
            EP_RS=""
            for cand in $(ls rust/crates/*/src/main.rs 2>/dev/null) rust/src/main.rs src/main.rs; do
                if [ -f "$cand" ]; then EP_RS="$cand"; break; fi
            done
            EP_RS="${EP_RS:-rust/src/main.rs}"

            EP="$EP_PY (python) + $EP_RS (rust)"  # display only; written below as separate vars
            ;;
    esac

    if [ "$LANG" = "python-rust" ]; then
        cat > .claude/hooks/project.conf <<EOF
# Auto-generated by guardrails/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# See guardrails/docs/LANG_MATRIX.md §Multi-lang projects for full reference.

LANGS="python rust"
ENTRY_POINTS_python="$EP_PY"
ENTRY_POINTS_rust="$EP_RS"

# Per-lang SRC_GLOBS / TEST_EXCLUDES / GHOST_SKIP_NAMES override the
# global ones if set. Example:
# SRC_GLOBS_python="python"
# SRC_GLOBS_rust="rust/crates"
EOF
    else
        cat > .claude/hooks/project.conf <<EOF
# Auto-generated by guardrails/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# See guardrails/docs/LANG_MATRIX.md for full reference.

LANG="$LANG"
ENTRY_POINTS="$EP"
EOF
    fi
    echo "  ✓ Created .claude/hooks/project.conf (LANG=$LANG, ENTRY_POINTS=$EP)"
    echo "     Verify the entry-point is correct. Edit if needed:"
    echo "       \$EDITOR .claude/hooks/project.conf"
else
    echo "  ⚠️  .claude/hooks/project.conf already exists — NOT overwriting."
fi

# 4. Initialize ghost baseline
if [ ! -f ".claude/ghost-baseline.txt" ]; then
    # The lang checker reads ENTRY_POINTS / SRC_GLOBS / TEST_EXCLUDES from
    # the process environment. `source` alone sets shell-locals; the child
    # `bash` invocation below is a separate shell and does NOT inherit
    # locals. Without `set -a` the checker exits early with "ENTRY_POINTS
    # env var required" and the redirect captures an empty file — the
    # baseline silently lands at 0 ghosts regardless of project state.
    set -a
    # shellcheck source=/dev/null
    source .claude/hooks/project.conf
    set +a
    if [ "$LANG" = "python-rust" ]; then
        # Run each lang's checker with its ENTRY_POINTS_<lang>; prefix lang:.
        # Also normalize file:line:symbol → file:symbol (drops middle field).
        TMP_BASE=$(mktemp)
        ENTRY_POINTS="${ENTRY_POINTS_python:-}" bash .claude/hooks/lang/python.sh 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print "python:" $1 ":" sym }' \
            >> "$TMP_BASE" || true
        ENTRY_POINTS="${ENTRY_POINTS_rust:-}" bash .claude/hooks/lang/rust.sh 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print "rust:" $1 ":" sym }' \
            >> "$TMP_BASE" || true
        sort -u "$TMP_BASE" > .claude/ghost-baseline.txt
        rm -f "$TMP_BASE"
    else
        # Single-lang: also normalize to file:symbol (matches integration-gate.sh format).
        bash ".claude/hooks/lang/$LANG.sh" 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print $1 ":" sym }' \
            > .claude/ghost-baseline.txt || true
    fi
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

# 6. Install the verify-* skill family (declarative-with-evidence layer).
#    Complements the mechanical hooks by letting the agent self-audit with
#    real command output before claiming completion in five orthogonal
#    domains: contract drift, completion claims, error paths, identity keys,
#    and storage integrity. See guardrails/skills/*.md.
if [ -d "$SCRIPT_DIR/skills" ]; then
    mkdir -p .claude/skills
    for skill_path in "$SCRIPT_DIR"/skills/*.md; do
        [ -f "$skill_path" ] || continue
        skill_name=$(basename "$skill_path")
        if [ -f ".claude/skills/$skill_name" ]; then
            echo "  ⚠️  .claude/skills/$skill_name already exists — NOT overwriting."
        else
            cp -f "$skill_path" ".claude/skills/$skill_name"
            echo "  ✓ Installed skill .claude/skills/$skill_name"
        fi
    done
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
