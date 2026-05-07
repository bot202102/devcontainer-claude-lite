# Multi-Lang Guardrails Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the `guardrails/` module so projects can have two languages active simultaneously (e.g. Python + Rust). Today the system assumes one `LANG` per repo. This plan adds a backwards-compatible `LANGS="python rust"` form: existing single-lang projects keep working unchanged; new dual-lang projects get both checkers running together with one merged baseline.

**Architecture:** `project.conf` accepts either `LANG=…` (current) **or** `LANGS=…` (new). Hooks read whichever is set and iterate. Baseline at `.claude/ghost-baseline.txt` is a single file with `lang:file:symbol` rows (lang prefix added when LANGS active; legacy single-lang baselines stay 2-field `file:symbol`). `install.sh` accepts a new `python-rust` meta-lang that pre-configures both checkers and the LANGS form. The PostToolUse hook gets a `lang_for_file()` helper that dispatches by file extension when LANGS is set.

**Tech Stack:** POSIX bash 4+ (Debian 12 has 5.2). No new dependencies.

**Repo / branch:**
- Repo: `bot202102/devcontainer-claude-lite`
- Local clone: `/home/rpach/Programacion/devcontainer-claude-lite`
- Working branch: `feat/guardrails-multi-lang` (to be created off `master`)
- Target PR base: `master`

**Issue:** [#27](https://github.com/bot202102/devcontainer-claude-lite/issues/27)

---

## File Structure

All paths relative to the `devcontainer-claude-lite` repo root.

**Modify:**
- `guardrails/.claude/hooks/project.conf.example` (~65 → ~95 lines) — document `LANGS` form.
- `guardrails/.claude/hooks/ghost-report.sh` (~76 → ~110 lines) — iterate over `LANGS`, prefix output with `lang:`.
- `guardrails/.claude/hooks/integration-gate.sh` (~131 → ~170 lines) — iterate over `LANGS`, baseline format becomes `lang:file:symbol` when LANGS active.
- `guardrails/.claude/hooks/new-symbol-guard.sh` (~122 → ~140 lines) — add `lang_for_file()` helper, dispatch to per-file lang.
- `guardrails/install.sh` (~229 → ~270 lines) — accept `python-rust` meta-lang.
- `guardrails/docs/LANG_MATRIX.md` (~718 → ~800 lines) — add **Multi-lang projects** section.
- `guardrails/README.md` (~222 → ~230 lines) — list `python-rust` in the supported-stack table.

**Create:**
- `guardrails/tests/python-rust/run_all.sh` — runner.
- `guardrails/tests/python-rust/test_python_only_unaffected.sh` — regression: single-lang LANG="python" still works exactly as before.
- `guardrails/tests/python-rust/test_baseline_split.sh` — multi-lang install creates baseline with `python:` and `rust:` prefixes.
- `guardrails/tests/python-rust/test_ghost_in_python_blocks.sh` — ghost added to Python side blocks Stop with exit 2 + clear message.
- `guardrails/tests/python-rust/test_ghost_in_rust_blocks.sh` — ghost added to Rust side blocks Stop with exit 2 + clear message.
- `guardrails/tests/python-rust/test_postool_picks_correct_checker.sh` — editing `.py` triggers Python check; editing `.rs` triggers Rust check.

**Backwards compatibility invariant:** Every existing project (single `LANG=…`) must continue to behave identically. Verified by `test_python_only_unaffected.sh` and the existing `guardrails/tests/python/run_all.sh` suite.

---

## Task 1: Branch setup

**Files:** none modified.

- [ ] **Step 1: Confirm starting state**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
git status
git branch --show-current
git log --oneline -1
```

Expected: clean tree, branch `master`, latest commit `afb541f feat(python-rust): add hybrid Python+Rust devcontainer template (#31)`.

- [ ] **Step 2: Create feature branch**

```bash
git checkout -b feat/guardrails-multi-lang
git status
```

Expected: `On branch feat/guardrails-multi-lang`, clean.

---

## Task 2: Document `LANGS` form in project.conf.example

**Files:**
- Modify: `guardrails/.claude/hooks/project.conf.example`

This task adds doc-only changes — no behavior. Lets the next tasks reference the documented format.

- [ ] **Step 1: Append the multi-lang section**

Open `guardrails/.claude/hooks/project.conf.example` and add the following block at the very end (after the existing `EXTRA_GHOST_PATTERNS` line):

```bash

# ─── Multi-lang projects (optional) ───────────────────────────────────
#
# If your project has two stacks active simultaneously (e.g. Python + Rust
# in the same repo), use LANGS instead of LANG. Mutually exclusive — set
# one or the other, never both.
#
#   LANGS="python rust"
#   ENTRY_POINTS_python="python/myapp/cli.py"
#   ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"
#
# Per-lang overrides for SRC_GLOBS / TEST_EXCLUDES use the same suffix
# pattern: SRC_GLOBS_python, TEST_EXCLUDES_rust, etc. Lang names with a
# hyphen (e.g. kotlin-android) become underscored in the variable name:
#   ENTRY_POINTS_kotlin_android="..."
#
# When LANGS is set, the baseline format (.claude/ghost-baseline.txt)
# carries a "lang:" prefix per row:
#   python:python/myapp/foo.py:orphan_function
#   rust:rust/crates/mycrate/src/lib.rs:OrphanStruct
#
# See guardrails/docs/LANG_MATRIX.md §Multi-lang projects.
# LANGS="python rust"
# ENTRY_POINTS_python="python/myapp/cli.py"
# ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"
```

- [ ] **Step 2: Verify the file parses as bash**

```bash
bash -n guardrails/.claude/hooks/project.conf.example
echo $?
```

Expected: `0`.

- [ ] **Step 3: Commit**

```bash
git add guardrails/.claude/hooks/project.conf.example
git commit -m "docs(guardrails): document LANGS form in project.conf.example

Pre-step for #27. No behavior change yet — just records the multi-lang
config shape so subsequent hook changes can reference it."
```

---

## Task 3: Make ghost-report.sh iterate over LANGS

**Files:**
- Modify: `guardrails/.claude/hooks/ghost-report.sh`

Refactor to handle either `LANG` (single) or `LANGS` (plural). When LANGS active, run each lang checker and prefix every output line with `lang:`.

- [ ] **Step 1: Replace the body of ghost-report.sh**

Open `guardrails/.claude/hooks/ghost-report.sh` and replace the section starting at line 27 (`if [ -z "${LANG:-}" ] || [ -z "${ENTRY_POINTS:-}" ]; then`) through line 47 (`exit 0` of the zero-ghost branch) with the multi-lang dispatch:

```bash
# Build list of (lang, entry-points) pairs.
# - If LANGS is set: iterate over each lang, look up ENTRY_POINTS_<lang>.
# - Else if LANG + ENTRY_POINTS set (legacy single-lang): one pair.
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

# Run each checker, prefix each output line with "lang:" only when MULTI.
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

    # Per-lang SRC_GLOBS / TEST_EXCLUDES / GHOST_SKIP_NAMES override the global ones if set.
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

# Use a representative ENTRY_POINTS string for messaging.
EP_DISPLAY="${ENTRY_POINTS:-multi-lang ($PAIRS_LANGS)}"

if [ "$GHOST_COUNT" -eq 0 ]; then
    echo "Integration gate: 0 ghost symbols — all public symbols have a call-site in $EP_DISPLAY."
    exit 0
fi
```

Then update line 49 (the `Ghost inventory at session start: …` line) and line 73 (the `Default behaviour for any NEW symbol …` line) to use `$EP_DISPLAY` instead of `$ENTRY_POINTS`.

The full replaced region (lines 27–end) should look like the snippet above followed by the existing top-5-directories logic + `head -20 $CURRENT` block + footer message — those parts are unchanged in their internal logic, just need `$ENTRY_POINTS` → `$EP_DISPLAY`.

- [ ] **Step 2: Smoke check the script parses**

```bash
bash -n guardrails/.claude/hooks/ghost-report.sh
echo $?
```

Expected: `0`.

- [ ] **Step 3: Smoke check single-lang still runs (no behavior regression)**

```bash
WORK=$(mktemp -d) && cd "$WORK"
mkdir -p src
cat > src/main.py <<'EOF'
def public_func(): return 1
public_func()
EOF
cat > project.conf <<EOF
LANG="python"
ENTRY_POINTS="src/main.py"
SRC_GLOBS="src"
EOF
mkdir -p hooks/lang
cp /home/rpach/Programacion/devcontainer-claude-lite/guardrails/.claude/hooks/ghost-report.sh hooks/
cp /home/rpach/Programacion/devcontainer-claude-lite/guardrails/.claude/hooks/lang/python.sh hooks/lang/
chmod +x hooks/*.sh hooks/lang/*.sh
ln -sf "$WORK/project.conf" hooks/project.conf
bash hooks/ghost-report.sh
cd - && rm -rf "$WORK"
```

Expected: prints `Integration gate: 0 ghost symbols — all public symbols have a call-site in src/main.py.`

- [ ] **Step 4: Commit**

```bash
git add guardrails/.claude/hooks/ghost-report.sh
git commit -m "feat(guardrails): ghost-report.sh iterates over LANGS

Single-lang LANG=… path unchanged. New: when LANGS is set, runs each
lang's checker with its ENTRY_POINTS_<lang> and prefixes output lines
with 'lang:' so the merged report stays sortable and unambiguous.

Refs #27"
```

---

## Task 4: Make integration-gate.sh iterate over LANGS

**Files:**
- Modify: `guardrails/.claude/hooks/integration-gate.sh`

Same iteration shape as `ghost-report.sh`, but the gate's job is harder: it normalizes to `file:symbol` and diffs against the baseline. With LANGS, normalized form becomes `lang:file:symbol`. Single-lang path keeps `file:symbol` unchanged.

- [ ] **Step 1: Replace the iteration block**

Open `guardrails/.claude/hooks/integration-gate.sh` and replace the section starting at line 32 (`if [ -z "${LANG:-}" ] || [ -z "${ENTRY_POINTS:-}" ]; then`) through line 49 (`bash "$LANG_CHECKER" | sort -u > "$CURRENT" || true`) with the multi-lang dispatch:

```bash
# Build (lang, EP) pairs (same logic as ghost-report.sh).
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
# still uses ":" as separator without ambiguity.
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
```

- [ ] **Step 2: Update the awk normalizer (lines 64–71 in pre-edit file)**

The awk that drops the line-number field needs to handle 3-field (`file:line:symbol`) and 4-field (`lang:file:line:symbol`) input differently. Replace the awk block with:

```bash
# Normalize CURRENT to baseline form:
#   single-lang: file:line:symbol  → file:symbol
#   multi-lang:  lang:file:line:symbol → lang:file:symbol
awk -F: -v OFS=: -v multi="$MULTI" '
{
    if (multi == "1") {
        # lang:file:line:symbol  (4+ fields, field 3 is digits if well-formed)
        lang = $1
        file = $2
        sym = $4
        for (i = 5; i <= NF; i++) sym = sym ":" $i
        print lang ":" file ":" sym
    } else {
        # file:line:symbol  (3+ fields, field 2 is digits if well-formed)
        file = $1
        sym = $3
        for (i = 4; i <= NF; i++) sym = sym ":" $i
        print file ":" sym
    }
}
' "$CURRENT" | sort -u > "$CURRENT_NORM"
```

- [ ] **Step 3: Update the legacy-baseline migration**

Lines 84–96 migrate `file:line:symbol` baselines to `file:symbol`. With LANGS active the legacy baseline is invalid (no lang prefix). Behavior: if MULTI=1 and the existing baseline lacks `lang:` prefixes, refuse with an actionable message — do NOT auto-migrate; the user should re-init.

Replace the migration block with:

```bash
if [ "$MULTI" = "1" ]; then
    # Multi-lang baseline format: lang:file:symbol (3+ fields, field 1 is a known lang).
    # Validate every non-empty, non-comment line has the prefix.
    if [ -f "$BASELINE" ]; then
        # First non-empty/non-comment line.
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
    fi
elif grep -qE '^[^:]+:[0-9]+:[^:]+$' "$BASELINE" 2>/dev/null; then
    TMP_MIGRATED=$(mktemp)
    awk -F: '
        NF == 3 && $2 ~ /^[0-9]+$/ { print $1 ":" $3; next }
        NF == 2 { print $0; next }
        { print }
    ' "$BASELINE" | sort -u > "$TMP_MIGRATED"
    mv "$TMP_MIGRATED" "$BASELINE"
    echo "integration-gate.sh: migrated baseline from file:line:symbol → file:symbol (one-shot)." >&2
fi
```

- [ ] **Step 4: Update the new-ghost recovery block (lines 103–112 pre-edit)**

The block recovers `file:line:symbol` from CURRENT for each new key. With MULTI=1 the key is `lang:file:symbol` and the matching CURRENT line is `lang:file:line:symbol`. Update grep:

```bash
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
```

- [ ] **Step 5: Update the gate-block message to use a representative EP**

Replace `$ENTRY_POINTS` in line 113 (`INTEGRATION GATE BLOCK: …`) with a `EP_DISPLAY` variable computed near the top:

```bash
EP_DISPLAY="${ENTRY_POINTS:-multi-lang ($PAIRS_LANGS)}"
```

And use `$EP_DISPLAY` in the `INTEGRATION GATE BLOCK:` line and the `for each symbol above, add a call-site from $EP_DISPLAY …` message.

- [ ] **Step 6: Verify script parses**

```bash
bash -n guardrails/.claude/hooks/integration-gate.sh
echo $?
```

Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add guardrails/.claude/hooks/integration-gate.sh
git commit -m "feat(guardrails): integration-gate.sh iterates over LANGS

Single-lang path unchanged: same baseline format (file:symbol), same
auto-migration of legacy file:line:symbol baselines.

Multi-lang path: when LANGS=\"python rust\" is set, each lang checker
runs with its ENTRY_POINTS_<lang>; output is prefixed with 'lang:' and
the baseline is keyed lang:file:symbol. A multi-lang run against a
legacy baseline (no lang prefix) refuses with an actionable rebuild
message — never silently mismigrates.

Refs #27"
```

---

## Task 5: Add `lang_for_file()` helper to new-symbol-guard.sh

**Files:**
- Modify: `guardrails/.claude/hooks/new-symbol-guard.sh`

PostToolUse: when a single file is edited, dispatch the per-extension language. Single-lang behavior unchanged. Multi-lang: pick the lang whose extension matches the edited file.

- [ ] **Step 1: Add helper function and dispatch**

Open `guardrails/.claude/hooks/new-symbol-guard.sh` and replace the section from line 25 (`[ -z "${LANG:-}" ] && exit 0`) through line 45 (the closing of the file-extension `case "$LANG"`) with:

```bash
# Helper: given a file path, return the lang name whose extension matches.
# Empty string if no known mapping.
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

# Resolve which lang this edit belongs to. Decision tree:
# 1. If LANGS is set: take the file's extension's lang; require it to be
#    in LANGS. If not, silent pass.
# 2. If LANG is set: keep the existing behavior (file extension must
#    match LANG's expected extensions).
if [ -n "${LANGS:-}" ]; then
    DETECTED=$(lang_for_file "$FILE_PATH")
    [ -z "$DETECTED" ] && exit 0
    # Resolve overlapping pairs: nextjs accepts node's extensions, java accepts kotlin's.
    # If DETECTED='node' but LANGS contains 'nextjs', use nextjs. Same for java/kotlin-android.
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

# Filter by extension for the resolved lang (existing behavior).
case "$EFF_LANG" in
    rust)            case "$FILE_PATH" in *.rs) ;; *) exit 0 ;; esac ;;
    python)          case "$FILE_PATH" in *.py) ;; *) exit 0 ;; esac ;;
    node|nextjs)     case "$FILE_PATH" in *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) ;; *) exit 0 ;; esac ;;
    go)              case "$FILE_PATH" in *.go) ;; *) exit 0 ;; esac ;;
    java)            case "$FILE_PATH" in *.java|*.kt) ;; *) exit 0 ;; esac ;;
    kotlin-android)  case "$FILE_PATH" in *.kt) ;; *) exit 0 ;; esac ;;
esac
```

Then in the symbol-extraction `case "$LANG"` (lines 54–82 in pre-edit file), replace `case "$LANG"` with `case "$EFF_LANG"`. Identical code paths for each branch.

In the call-site check (line 97), replace `for ep in $ENTRY_POINTS` with `for ep in $EFF_EP`.

In the warning message (line 114), use `$EFF_EP` instead of `$ENTRY_POINTS`.

- [ ] **Step 2: Verify parses**

```bash
bash -n guardrails/.claude/hooks/new-symbol-guard.sh
echo $?
```

Expected: `0`.

- [ ] **Step 3: Commit**

```bash
git add guardrails/.claude/hooks/new-symbol-guard.sh
git commit -m "feat(guardrails): new-symbol-guard.sh resolves lang per file in LANGS mode

Adds lang_for_file() helper that maps file extension → lang name.
When LANGS is set, each Edit/Write resolves to one lang based on the
edited file's extension; the existing single-LANG path is unchanged.

Handles two overlapping pairs:
- If LANGS contains both 'node' and 'nextjs', picks 'nextjs' for
  .ts/.tsx/.js/.jsx/.mjs/.cjs (the more specific checker wins).
- If LANGS contains both 'java' and 'kotlin-android', picks 'java' for
  .kt (the more general server-side checker wins for non-Android repos).

Refs #27"
```

---

## Task 6: Update install.sh to accept python-rust meta-lang

**Files:**
- Modify: `guardrails/install.sh`

Add `python-rust` as an accepted lang. When chosen, install BOTH `python.sh` and `rust.sh` checkers and write a project.conf with `LANGS="python rust"`.

- [ ] **Step 1: Extend the validate-lang case (line 45)**

Replace:

```bash
case "$LANG" in
    rust|python|node|astro|nextjs|go|java|kotlin-android) ;;
    *)
        echo "Unsupported language: $LANG" >&2
        echo "Supported: rust | python | node | astro | nextjs | go | java | kotlin-android" >&2
        exit 1
        ;;
esac
```

With:

```bash
case "$LANG" in
    rust|python|node|astro|nextjs|go|java|kotlin-android) ;;
    python-rust) ;;  # meta-lang: installs both python.sh + rust.sh
    *)
        echo "Unsupported language: $LANG" >&2
        echo "Supported: rust | python | node | astro | nextjs | go | java | kotlin-android | python-rust" >&2
        exit 1
        ;;
esac
```

- [ ] **Step 2: Extend the checker copy (line 64)**

Replace the single-checker copy line:

```bash
cp -f "$SCRIPT_DIR/.claude/hooks/lang/$LANG.sh" .claude/hooks/lang/
```

With:

```bash
if [ "$LANG" = "python-rust" ]; then
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/python.sh" .claude/hooks/lang/
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/rust.sh" .claude/hooks/lang/
else
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/$LANG.sh" .claude/hooks/lang/
fi
```

- [ ] **Step 3: Extend the entry-point heuristic + project.conf generation (lines 78–158)**

After the existing `case "$LANG" in` block that builds `$EP`, add a new `python-rust` branch. Replace:

```bash
        kotlin-android)
            # ... existing kotlin block ...
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
```

With:

```bash
        kotlin-android)
            # ... existing kotlin block ...
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
```

- [ ] **Step 4: Update the baseline-init block (line 161)**

Replace:

```bash
    bash ".claude/hooks/lang/$LANG.sh" 2>/dev/null | sort -u > .claude/ghost-baseline.txt || true
```

With:

```bash
    if [ "$LANG" = "python-rust" ]; then
        # Run each lang's checker with its ENTRY_POINTS_<lang>, prefix lang:.
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
        bash ".claude/hooks/lang/$LANG.sh" 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print $1 ":" sym }' \
            > .claude/ghost-baseline.txt || true
    fi
```

(Note: this also normalizes the single-lang baseline to `file:symbol` at install time, which is what `integration-gate.sh` already does on first-run anyway. Net behavior identical for single-lang; required for python-rust to produce the correct prefix-bearing format from the start.)

- [ ] **Step 5: Update usage banner (line 36)**

Append `python-rust` to the langs list in the usage error message:

```bash
echo "  langs: rust | python | node | astro | nextjs | go | java | kotlin-android | python-rust" >&2
```

- [ ] **Step 6: Verify parses**

```bash
bash -n guardrails/install.sh
echo $?
```

Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add guardrails/install.sh
git commit -m "feat(guardrails): install.sh accepts python-rust meta-lang

When LANG arg is 'python-rust', install.sh:
- Copies both python.sh and rust.sh checkers
- Writes project.conf with LANGS=\"python rust\" + ENTRY_POINTS_<lang>
- Captures baseline with lang: prefixes for both checkers' output

Heuristic entry-points: python/<pkg>/cli.py and rust/crates/*/src/main.rs;
falls back gracefully to project root paths.

Refs #27"
```

---

## Task 7: Create test scaffolding

**Files:**
- Create: `guardrails/tests/python-rust/run_all.sh`

- [ ] **Step 1: Write run_all.sh**

Create `guardrails/tests/python-rust/run_all.sh` with:

```bash
#!/usr/bin/env bash
# run_all.sh — run every multi-lang regression test in this directory.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$SCRIPT_DIR"/*.sh
FAIL=0
for t in "$SCRIPT_DIR"/test_*.sh; do
    echo ""
    echo "═══ $(basename "$t") ═══"
    if bash "$t"; then
        :
    else
        FAIL=$((FAIL + 1))
    fi
done
echo ""
if [ $FAIL -gt 0 ]; then
    echo "❌ $FAIL multi-lang test(s) failed"
    exit 1
fi
echo "✅ all multi-lang regression tests passed"
```

- [ ] **Step 2: Verify**

```bash
chmod +x guardrails/tests/python-rust/run_all.sh
bash -n guardrails/tests/python-rust/run_all.sh
ls -la guardrails/tests/python-rust/
```

Expected: `run_all.sh` exists, executable, parses.

- [ ] **Step 3: Commit (will be re-stamped after test files added)**

Hold off committing until Task 8–12 add the actual tests; commit them all together at end of Task 12.

---

## Task 8: Test — single-lang regression (LANG=python unaffected)

**Files:**
- Create: `guardrails/tests/python-rust/test_python_only_unaffected.sh`

This is the safety-net test: existing single-lang projects must keep working bit-identically.

- [ ] **Step 1: Write test**

Create `guardrails/tests/python-rust/test_python_only_unaffected.sh`:

```bash
#!/usr/bin/env bash
# test_python_only_unaffected.sh — single-lang LANG=python projects must
# behave exactly as they did pre-#27 (regresión 0).
#
# Asserts: integration-gate.sh on a clean single-lang Python project
# creates the baseline in 2-field file:symbol format (no lang prefix)
# and reports zero new ghosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture: 1 entry-point + 1 wired module + 1 ghost.
mkdir -p "$WORK/src/pkg"
cat > "$WORK/src/main.py" <<'EOF'
from pkg.wired import wired_func
if __name__ == "__main__":
    wired_func()
EOF
touch "$WORK/src/pkg/__init__.py"
cat > "$WORK/src/pkg/wired.py" <<'EOF'
def wired_func():
    return 1
EOF
cat > "$WORK/src/pkg/ghost.py" <<'EOF'
def lonely_ghost():
    return 42
EOF

cd "$WORK"
mkdir -p .claude/hooks/lang
cp "$GUARDRAILS_ROOT/.claude/hooks/integration-gate.sh" .claude/hooks/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"      .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

cat > .claude/hooks/project.conf <<EOF
LANG="python"
ENTRY_POINTS="src/main.py"
SRC_GLOBS="src"
EOF

# First run: creates baseline. exit 0 expected.
set +e
bash .claude/hooks/integration-gate.sh
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: first run should exit 0 (creates baseline). Got $RC" >&2
    exit 1
fi

if [ ! -f .claude/ghost-baseline.txt ]; then
    echo "FAIL: baseline not created" >&2
    exit 1
fi

# Assert format: every line is exactly file:symbol (2 colons-separated fields, NO 'python:' prefix).
if grep -qE '^python:' .claude/ghost-baseline.txt; then
    echo "FAIL: single-lang baseline has 'python:' prefix (regression — should be file:symbol)" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

if ! grep -q "lonely_ghost" .claude/ghost-baseline.txt; then
    echo "FAIL: ghost not captured in baseline" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

# Second run: zero new ghosts. exit 0.
set +e
bash .claude/hooks/integration-gate.sh
RC2=$?
set -e
if [ $RC2 -ne 0 ]; then
    echo "FAIL: second run with unchanged code should exit 0. Got $RC2" >&2
    exit 1
fi

echo "PASS: single-lang LANG=python behavior unchanged (no lang prefix, baseline file:symbol)"
```

- [ ] **Step 2: Run it**

```bash
chmod +x guardrails/tests/python-rust/test_python_only_unaffected.sh
bash guardrails/tests/python-rust/test_python_only_unaffected.sh
```

Expected: `PASS: single-lang LANG=python behavior unchanged …`. If any earlier task introduced a single-lang regression, this fails first.

---

## Task 9: Test — baseline split (multi-lang produces lang: prefixes)

**Files:**
- Create: `guardrails/tests/python-rust/test_baseline_split.sh`

- [ ] **Step 1: Write test**

Create `guardrails/tests/python-rust/test_baseline_split.sh`:

```bash
#!/usr/bin/env bash
# test_baseline_split.sh — multi-lang install must produce a baseline with
# both 'python:' and 'rust:' prefixed entries when both sides have ghosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture: python/ + rust/ siblings with one ghost each.
mkdir -p "$WORK/python/myapp" "$WORK/rust/crates/mycrate/src"
cat > "$WORK/python/myapp/cli.py" <<'EOF'
from myapp.wired import wired_py
if __name__ == "__main__":
    wired_py()
EOF
touch "$WORK/python/myapp/__init__.py"
cat > "$WORK/python/myapp/wired.py" <<'EOF'
def wired_py():
    return 1
EOF
cat > "$WORK/python/myapp/ghost.py" <<'EOF'
def python_ghost_func():
    return 99
EOF

cat > "$WORK/rust/crates/mycrate/Cargo.toml" <<'EOF'
[package]
name = "mycrate"
version = "0.1.0"
edition = "2021"
EOF
cat > "$WORK/rust/crates/mycrate/src/main.rs" <<'EOF'
fn main() {
    println!("hello");
}
EOF
cat > "$WORK/rust/crates/mycrate/src/lib.rs" <<'EOF'
pub fn rust_ghost_func() -> i32 {
    99
}
EOF

cd "$WORK"
mkdir -p .claude/hooks/lang
cp "$GUARDRAILS_ROOT/.claude/hooks/integration-gate.sh" .claude/hooks/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"      .claude/hooks/lang/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/rust.sh"        .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

cat > .claude/hooks/project.conf <<EOF
LANGS="python rust"
ENTRY_POINTS_python="python/myapp/cli.py"
ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"
SRC_GLOBS_python="python"
SRC_GLOBS_rust="rust/crates"
EOF

# First run: creates multi-lang baseline. exit 0.
set +e
bash .claude/hooks/integration-gate.sh
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: first run exit code $RC (expected 0)" >&2
    exit 1
fi

# Assert baseline contains both prefixes.
if ! grep -qE '^python:' .claude/ghost-baseline.txt; then
    echo "FAIL: baseline missing 'python:' prefix entries" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi
if ! grep -qE '^rust:' .claude/ghost-baseline.txt; then
    echo "FAIL: baseline missing 'rust:' prefix entries" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi
if ! grep -q "python_ghost_func" .claude/ghost-baseline.txt; then
    echo "FAIL: python ghost not captured" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi
if ! grep -q "rust_ghost_func" .claude/ghost-baseline.txt; then
    echo "FAIL: rust ghost not captured" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

echo "PASS: multi-lang baseline has both python: and rust: prefixed entries"
```

- [ ] **Step 2: Run it**

```bash
chmod +x guardrails/tests/python-rust/test_baseline_split.sh
bash guardrails/tests/python-rust/test_baseline_split.sh
```

Expected: `PASS: multi-lang baseline has both python: and rust: prefixed entries`.

---

## Task 10: Test — ghost in Python blocks Stop

**Files:**
- Create: `guardrails/tests/python-rust/test_ghost_in_python_blocks.sh`

- [ ] **Step 1: Write test**

Create `guardrails/tests/python-rust/test_ghost_in_python_blocks.sh`:

```bash
#!/usr/bin/env bash
# test_ghost_in_python_blocks.sh — adding a NEW ghost on the Python side
# (after the multi-lang baseline is captured) must trigger integration-gate
# exit 2 with a message that contains 'python:' and the new symbol name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Re-use the same fixture shape as test_baseline_split.sh.
mkdir -p "$WORK/python/myapp" "$WORK/rust/crates/mycrate/src"
cat > "$WORK/python/myapp/cli.py" <<'EOF'
from myapp.wired import wired_py
if __name__ == "__main__":
    wired_py()
EOF
touch "$WORK/python/myapp/__init__.py"
cat > "$WORK/python/myapp/wired.py" <<'EOF'
def wired_py():
    return 1
EOF
cat > "$WORK/python/myapp/ghost.py" <<'EOF'
def python_existing_ghost():
    return 99
EOF

cat > "$WORK/rust/crates/mycrate/src/main.rs" <<'EOF'
fn main() {
    println!("hello");
}
EOF
cat > "$WORK/rust/crates/mycrate/src/lib.rs" <<'EOF'
pub fn rust_existing_ghost() -> i32 {
    99
}
EOF
cat > "$WORK/rust/crates/mycrate/Cargo.toml" <<'EOF'
[package]
name = "mycrate"
version = "0.1.0"
edition = "2021"
EOF

cd "$WORK"
mkdir -p .claude/hooks/lang
cp "$GUARDRAILS_ROOT/.claude/hooks/integration-gate.sh" .claude/hooks/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"      .claude/hooks/lang/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/rust.sh"        .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

cat > .claude/hooks/project.conf <<EOF
LANGS="python rust"
ENTRY_POINTS_python="python/myapp/cli.py"
ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"
SRC_GLOBS_python="python"
SRC_GLOBS_rust="rust/crates"
EOF

# Run 1: capture baseline.
bash .claude/hooks/integration-gate.sh > /dev/null

# Add a NEW python ghost.
cat > "$WORK/python/myapp/new_ghost.py" <<'EOF'
def python_NEW_ghost():
    return 7
EOF

# Run 2: must exit 2 and mention python:.
set +e
OUTPUT=$(bash .claude/hooks/integration-gate.sh 2>&1)
RC=$?
set -e

if [ $RC -ne 2 ]; then
    echo "FAIL: expected exit 2 (block), got $RC" >&2
    echo "Output:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "python_NEW_ghost"; then
    echo "FAIL: gate output missing the new ghost name 'python_NEW_ghost'" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "python:"; then
    echo "FAIL: gate output missing 'python:' lang prefix in the new ghost line" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "PASS: new python ghost blocks gate (exit 2) with python: prefix in message"
```

- [ ] **Step 2: Run**

```bash
chmod +x guardrails/tests/python-rust/test_ghost_in_python_blocks.sh
bash guardrails/tests/python-rust/test_ghost_in_python_blocks.sh
```

Expected: PASS.

---

## Task 11: Test — ghost in Rust blocks Stop

**Files:**
- Create: `guardrails/tests/python-rust/test_ghost_in_rust_blocks.sh`

- [ ] **Step 1: Write test**

Create `guardrails/tests/python-rust/test_ghost_in_rust_blocks.sh`:

```bash
#!/usr/bin/env bash
# test_ghost_in_rust_blocks.sh — adding a NEW ghost on the Rust side
# (after the multi-lang baseline is captured) must trigger integration-gate
# exit 2 with a message that contains 'rust:' and the new symbol name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Same fixture shape as test_ghost_in_python_blocks.sh.
mkdir -p "$WORK/python/myapp" "$WORK/rust/crates/mycrate/src"
cat > "$WORK/python/myapp/cli.py" <<'EOF'
from myapp.wired import wired_py
if __name__ == "__main__":
    wired_py()
EOF
touch "$WORK/python/myapp/__init__.py"
cat > "$WORK/python/myapp/wired.py" <<'EOF'
def wired_py():
    return 1
EOF
cat > "$WORK/python/myapp/ghost.py" <<'EOF'
def python_existing_ghost():
    return 99
EOF

cat > "$WORK/rust/crates/mycrate/src/main.rs" <<'EOF'
fn main() {
    println!("hello");
}
EOF
cat > "$WORK/rust/crates/mycrate/src/lib.rs" <<'EOF'
pub fn rust_existing_ghost() -> i32 {
    99
}
EOF
cat > "$WORK/rust/crates/mycrate/Cargo.toml" <<'EOF'
[package]
name = "mycrate"
version = "0.1.0"
edition = "2021"
EOF

cd "$WORK"
mkdir -p .claude/hooks/lang
cp "$GUARDRAILS_ROOT/.claude/hooks/integration-gate.sh" .claude/hooks/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"      .claude/hooks/lang/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/rust.sh"        .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

cat > .claude/hooks/project.conf <<EOF
LANGS="python rust"
ENTRY_POINTS_python="python/myapp/cli.py"
ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"
SRC_GLOBS_python="python"
SRC_GLOBS_rust="rust/crates"
EOF

# Run 1: capture baseline.
bash .claude/hooks/integration-gate.sh > /dev/null

# Add a NEW rust ghost in a sibling module. Declaring `pub mod extra;` in
# lib.rs makes the file part of the crate but main.rs never invokes
# rust_NEW_ghost — so it remains an unreachable public symbol (ghost).
mkdir -p "$WORK/rust/crates/mycrate/src/extra"
cat > "$WORK/rust/crates/mycrate/src/extra/mod.rs" <<'EOF'
pub fn rust_NEW_ghost() -> i32 {
    7
}
EOF
echo "pub mod extra;" >> "$WORK/rust/crates/mycrate/src/lib.rs"

# Run 2: must exit 2 and mention rust:.
set +e
OUTPUT=$(bash .claude/hooks/integration-gate.sh 2>&1)
RC=$?
set -e

if [ $RC -ne 2 ]; then
    echo "FAIL: expected exit 2 (block), got $RC" >&2
    echo "Output:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "rust_NEW_ghost"; then
    echo "FAIL: gate output missing the new ghost name 'rust_NEW_ghost'" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "rust:"; then
    echo "FAIL: gate output missing 'rust:' lang prefix in the new ghost line" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "PASS: new rust ghost blocks gate (exit 2) with rust: prefix in message"
```

- [ ] **Step 2: Run**

```bash
chmod +x guardrails/tests/python-rust/test_ghost_in_rust_blocks.sh
bash guardrails/tests/python-rust/test_ghost_in_rust_blocks.sh
```

Expected: PASS.

---

## Task 12: Test — postool dispatches by file extension

**Files:**
- Create: `guardrails/tests/python-rust/test_postool_picks_correct_checker.sh`

- [ ] **Step 1: Write test**

Create `guardrails/tests/python-rust/test_postool_picks_correct_checker.sh`:

```bash
#!/usr/bin/env bash
# test_postool_picks_correct_checker.sh — new-symbol-guard.sh under LANGS
# must dispatch by file extension. Editing a .py file uses Python rules
# (warn on def/class without _ prefix); editing a .rs file uses Rust rules
# (warn on pub fn/struct/enum/trait without caller).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/python" "$WORK/rust/src" "$WORK/.claude/hooks/lang"
cp "$GUARDRAILS_ROOT/.claude/hooks/new-symbol-guard.sh" "$WORK/.claude/hooks/"
chmod +x "$WORK/.claude/hooks/new-symbol-guard.sh"

cat > "$WORK/python/orphan.py" <<'EOF'
def py_orphan():
    return 1
EOF
cat > "$WORK/rust/src/orphan.rs" <<'EOF'
pub fn rust_orphan() -> i32 {
    1
}
EOF
cat > "$WORK/python/main.py" <<'EOF'
print("hi")
EOF
cat > "$WORK/rust/src/main.rs" <<'EOF'
fn main() {}
EOF

cd "$WORK"
cat > .claude/hooks/project.conf <<EOF
LANGS="python rust"
ENTRY_POINTS_python="python/main.py"
ENTRY_POINTS_rust="rust/src/main.rs"
EOF

# Edit .py → expect warning mentioning 'py_orphan'.
PY_OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$WORK"'/python/orphan.py"}}' \
    | bash .claude/hooks/new-symbol-guard.sh 2>&1)
if ! echo "$PY_OUT" | grep -q "py_orphan"; then
    echo "FAIL: editing .py did not warn on py_orphan" >&2
    echo "$PY_OUT" >&2
    exit 1
fi

# Edit .rs → expect warning mentioning 'rust_orphan'.
RS_OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$WORK"'/rust/src/orphan.rs"}}' \
    | bash .claude/hooks/new-symbol-guard.sh 2>&1)
if ! echo "$RS_OUT" | grep -q "rust_orphan"; then
    echo "FAIL: editing .rs did not warn on rust_orphan" >&2
    echo "$RS_OUT" >&2
    exit 1
fi

# Edit .ts (not in LANGS) → silent pass (no warning).
TS_FILE="$WORK/python/something.ts"
echo "export const foo = 1" > "$TS_FILE"
TS_OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$TS_FILE"'"}}' \
    | bash .claude/hooks/new-symbol-guard.sh 2>&1)
if [ -n "$TS_OUT" ]; then
    echo "FAIL: editing .ts (not in LANGS) produced output: $TS_OUT" >&2
    exit 1
fi

echo "PASS: postool dispatches by file extension under LANGS"
```

- [ ] **Step 2: Run**

```bash
chmod +x guardrails/tests/python-rust/test_postool_picks_correct_checker.sh
bash guardrails/tests/python-rust/test_postool_picks_correct_checker.sh
```

Expected: PASS.

- [ ] **Step 3: Commit all 5 tests**

```bash
git add guardrails/tests/python-rust/
git commit -m "test(guardrails): add 5 multi-lang regression tests

Covers:
- Single-lang LANG=python regression (file:symbol baseline, no prefix)
- Multi-lang baseline format (python: + rust: prefixes)
- New ghost in Python blocks gate with exit 2
- New ghost in Rust blocks gate with exit 2
- PostToolUse dispatches by file extension under LANGS

Refs #27"
```

---

## Task 13: Run full test suite — verify no regressions

**Files:** none modified.

- [ ] **Step 1: Run multi-lang suite**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
bash guardrails/tests/python-rust/run_all.sh
```

Expected: `✅ all multi-lang regression tests passed`.

- [ ] **Step 2: Run existing python suite (regression)**

```bash
bash guardrails/tests/python/run_all.sh
```

Expected: `✅ all python.sh regression tests passed` — same output as on master.

- [ ] **Step 3: Stop if either suite failed**

If multi-lang fails: review the failing test's `OUTPUT` print, find the broken hook, fix in place, re-run.
If python suite fails: a single-lang regression has been introduced. Locate via `git diff master -- guardrails/.claude/hooks/`. Single-lang invariants must be preserved.

---

## Task 14: Smoke-test install.sh end-to-end

**Files:** none modified (verification only).

- [ ] **Step 1: Run install on a synthetic python-rust project**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
WORK=$(mktemp -d)
mkdir -p "$WORK/python/myapp" "$WORK/rust/crates/mycrate/src"
cat > "$WORK/python/myapp/cli.py" <<'EOF'
def main(): print("hi")
if __name__ == "__main__": main()
EOF
touch "$WORK/python/myapp/__init__.py"
cat > "$WORK/python/myapp/ghost.py" <<'EOF'
def py_ghost(): return 1
EOF
cat > "$WORK/rust/crates/mycrate/src/main.rs" <<'EOF'
fn main() {}
EOF
cat > "$WORK/rust/crates/mycrate/src/lib.rs" <<'EOF'
pub fn rs_ghost() -> i32 { 1 }
EOF

bash guardrails/install.sh "$WORK" python-rust
```

Expected: install succeeds with these messages (exact strings may vary):
- `✓ Copied hook scripts to .claude/hooks/`
- `✓ Created .claude/hooks/project.conf` (or `⚠️ already exists` — acceptable on rerun)
- `✓ Captured ghost baseline (2 inherited symbols) at .claude/ghost-baseline.txt` (the two ghosts: py_ghost + rs_ghost)

- [ ] **Step 2: Inspect output state**

```bash
cat "$WORK/.claude/hooks/project.conf"
cat "$WORK/.claude/ghost-baseline.txt"
ls "$WORK/.claude/hooks/lang/"
```

Expected:
- `project.conf` contains `LANGS="python rust"`, `ENTRY_POINTS_python=…`, `ENTRY_POINTS_rust=…`
- `ghost-baseline.txt` has 2 lines: one starting with `python:`, one with `rust:`
- `.claude/hooks/lang/` contains both `python.sh` and `rust.sh`

- [ ] **Step 3: Cleanup**

```bash
rm -rf "$WORK"
```

---

## Task 15: Update LANG_MATRIX.md with Multi-lang section

**Files:**
- Modify: `guardrails/docs/LANG_MATRIX.md`

- [ ] **Step 1: Append Multi-lang section**

Append the following section at the end of `guardrails/docs/LANG_MATRIX.md`:

````markdown

---

## Multi-lang projects

When a single repo has two stacks active simultaneously (e.g. Python + Rust), use `LANGS` instead of `LANG`. Mutually exclusive — set one or the other, never both.

### project.conf

```bash
LANGS="python rust"
ENTRY_POINTS_python="python/myapp/cli.py"
ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"

# Per-lang overrides for SRC_GLOBS / TEST_EXCLUDES / GHOST_SKIP_NAMES
# use the same suffix pattern. Hyphens in lang names → underscores.
SRC_GLOBS_python="python"
SRC_GLOBS_rust="rust/crates"
# TEST_EXCLUDES_kotlin_android="..."
```

### Baseline format under LANGS

The `.claude/ghost-baseline.txt` carries a `lang:` prefix on every row:

```
python:python/myapp/foo.py:orphan_function
rust:rust/crates/mycrate/src/lib.rs:OrphanStruct
```

A multi-lang run against a legacy 2-field baseline (`file:symbol` without prefix) refuses with an actionable rebuild message rather than guessing — re-run the install or `rm .claude/ghost-baseline.txt` and re-capture.

### How each hook iterates

| Hook | Behavior under LANGS |
|---|---|
| `ghost-report.sh` (SessionStart) | Runs each lang's checker with its `ENTRY_POINTS_<lang>`; merges output sorted with `lang:` prefixes. |
| `integration-gate.sh` (Stop) | Same iteration; new ghosts in ANY lang trigger `exit 2`. |
| `new-symbol-guard.sh` (PostToolUse) | Uses `lang_for_file()` helper to pick the lang based on the edited file's extension; only warns if the resolved lang is in `LANGS`. |

### Overlapping pairs

Two lang pairs share file extensions:
- `node` and `nextjs` both consume `.ts/.tsx/.js/.jsx/.mjs/.cjs`. If both are in `LANGS`, `nextjs` wins (more specific).
- `java` and `kotlin-android` both consume `.kt`. If both are in `LANGS`, `java` wins (more general server-side).

### Installing via meta-lang

`install.sh` supports `python-rust` as a shortcut for the most common pairing:

```bash
bash guardrails/install.sh /path/to/your-project python-rust
```

This installs both `python.sh` and `rust.sh` checkers, writes `project.conf` with `LANGS="python rust"`, and captures the initial baseline with prefixes.

For other combinations (e.g. `python go`, `node rust`), invoke `install.sh` once per lang then hand-edit `project.conf` to merge into a single `LANGS=…` entry.

### Backwards compatibility

| Existing config | Behavior after #27 |
|---|---|
| `LANG="rust"` + `ENTRY_POINTS=…` | Identical — `LANGS` not set, falls back to single-lang path. |
| `LANG="python"` + `ENTRY_POINTS=…` | Identical. |
| `LANG="kotlin-android"` with multi-EP `ENTRY_POINTS=…` | Identical (multi-EP within a single LANG already worked). |
| Pre-existing `ghost-baseline.txt` in `file:line:symbol` format | Auto-migrated to `file:symbol` on next gate run, same as today. |

The `test_python_only_unaffected.sh` test fixture asserts this invariant.
````

- [ ] **Step 2: Verify markdown is valid**

```bash
wc -l guardrails/docs/LANG_MATRIX.md
grep -n "## Multi-lang projects" guardrails/docs/LANG_MATRIX.md
```

Expected: line count ~800, single match for the new heading.

- [ ] **Step 3: Commit**

```bash
git add guardrails/docs/LANG_MATRIX.md
git commit -m "docs(guardrails): add Multi-lang projects section to LANG_MATRIX

Documents LANGS form, baseline prefix format, per-hook iteration model,
overlapping-pair resolution rules, and backwards-compat invariants.

Refs #27"
```

---

## Task 16: Update guardrails/README.md

**Files:**
- Modify: `guardrails/README.md`

- [ ] **Step 1: Find the supported-langs reference and add python-rust**

Use grep to locate the install command example:

```bash
grep -n "guardrails/install.sh" guardrails/README.md | head -5
```

The first match is typically a usage example. Update the langs list there to include `python-rust`. Specifically, find a line like:

```
bash guardrails/install.sh /ruta/a/tu-proyecto rust   # o python, node, go, java
```

And replace with:

```
bash guardrails/install.sh /ruta/a/tu-proyecto rust   # o python, node, astro, nextjs, go, java, kotlin-android, python-rust
```

Then add a brief paragraph after the install command:

```markdown
**Multi-lang**: para repos con dos stacks activos al mismo tiempo (ej. Python + Rust), usa el meta-lang `python-rust`. Detalles en [docs/LANG_MATRIX.md §Multi-lang projects](docs/LANG_MATRIX.md#multi-lang-projects).
```

- [ ] **Step 2: Commit**

```bash
git add guardrails/README.md
git commit -m "docs(guardrails): mention python-rust meta-lang in README

Refs #27"
```

---

## Task 17: Push branch and open PR

**Files:** none modified.

- [ ] **Step 1: Final review**

```bash
cd /home/rpach/Programacion/devcontainer-claude-lite
git status
git log --oneline master..HEAD
```

Expected: clean tree; ~7 commits between master and HEAD (one per Task 2/3/4/5/6/12/15/16).

- [ ] **Step 2: Push**

```bash
git push -u origin feat/guardrails-multi-lang
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base master --title "feat(guardrails): support multi-language projects (LANGS=\"python rust\")" --body "$(cat <<'EOF'
## Summary

Implements [#27](https://github.com/bot202102/devcontainer-claude-lite/issues/27): backwards-compatible multi-lang support. Existing single-`LANG` projects keep working bit-identically (regression test enforces this); new dual-lang projects use `LANGS=\"python rust\"` form.

Closes #27.

## What changed

- **`project.conf.example`**: documents `LANGS=…` + `ENTRY_POINTS_<lang>` form.
- **Hooks**: `ghost-report.sh`, `integration-gate.sh`, `new-symbol-guard.sh` all iterate over `LANGS` when set; fall back to single-lang `LANG`+`ENTRY_POINTS` otherwise.
- **Baseline format**: under `LANGS`, rows carry a `lang:` prefix (`python:src/foo.py:bar`). Single-lang baselines stay 2-field `file:symbol`.
- **`install.sh`**: new `python-rust` meta-lang installs both `python.sh`+`rust.sh` checkers and pre-writes `LANGS=\"python rust\"` config.
- **Tests**: 5 new regression tests under `guardrails/tests/python-rust/`.
- **Docs**: `LANG_MATRIX.md` gains a Multi-lang section; `README.md` references the meta-lang.

## Verification

- [x] `bash guardrails/tests/python-rust/run_all.sh` → 5/5 PASS
- [x] `bash guardrails/tests/python/run_all.sh` → unchanged (no single-lang regression)
- [x] Smoke test: `bash guardrails/install.sh /tmp/test python-rust` → produces `LANGS=\"python rust\"` config + dual-prefix baseline

## Out of scope

- `python-go`, `node-rust`, etc. as meta-langs — not auto-handled by `install.sh` yet (manual config required). The hook layer supports any `LANGS=…` combination; only the `install.sh` shortcut is python-rust-specific.

## Related

- Consumer: `bot202102/audio-a-texto` (separate upstream PR will use this).
- Plan doc: `docs/superpowers/plans/2026-05-07-multi-lang-guardrails.md` (committed in this PR).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 4: Verify PR open and mergeable**

```bash
gh pr view --json state,mergeable,mergeStateStatus,number,url
```

Expected: `state: OPEN`, `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`.

---

## Definition of Done

All of the following must be true after Task 17:

1. Branch `feat/guardrails-multi-lang` exists on origin with ~7-9 commits.
2. PR is open against `master`, mergeable, no conflicts.
3. `guardrails/tests/python-rust/run_all.sh` passes 5/5.
4. `guardrails/tests/python/run_all.sh` passes unchanged (regression 0).
5. `bash guardrails/install.sh /tmp/test-pyrust python-rust` succeeds and produces a project.conf with `LANGS="python rust"` plus a baseline with both `python:` and `rust:` rows.
6. `guardrails/.claude/hooks/integration-gate.sh` exits 2 with a `lang:`-prefixed message when a new ghost is added on either side of a multi-lang project.
7. `guardrails/docs/LANG_MATRIX.md` has a `## Multi-lang projects` section explaining the model.
8. `guardrails/README.md` mentions `python-rust` in the supported-langs line.
9. The plan document `docs/superpowers/plans/2026-05-07-multi-lang-guardrails.md` is committed (it will be when the PR includes the working tree it was written in).

After PR is reviewed and merged, the consumer `bot202102/audio-a-texto` can call `bash guardrails/install.sh . python-rust` and get full multi-lang coverage.
