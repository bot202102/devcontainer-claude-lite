#!/usr/bin/env bash
# kotlin-android.sh — public Kotlin top-level declarations (class/object/interface/
# enum/sealed/data class, top-level fun, top-level @Composable fun) without a
# call-site reachable from Android entry-points.
#
# Reachability sources (a symbol is "reachable" if its name appears in any of):
#   - ENTRY_POINTS verbatim files (typically MainActivity.kt + Application class)
#   - All .kt and .xml files in same dir tree as each ENTRY_POINT (1-hop transitive)
#   - AndroidManifest.xml — catches manifest-declared Activity/Service/Receiver/Provider
#   - Auto-discovered Koin module files — any .kt with Koin DSL pattern (`module {`)
#
# Why Android-specific:
#   - Kotlin classes are public by default (no `public` keyword) — visibility filter
#     must reject `private`/`internal`/`protected`/`@VisibleForTesting`-prefixed.
#   - Many production classes are wired exclusively via Koin DSL string-free
#     (`single { Foo() }` / `viewModel { FooViewModel(get()) }`) — must scan
#     module files as reachability sources.
#   - Compose screens are top-level `fun`s called from a NavGraph composable —
#     graph file (typically MoytrixApp.kt or NavGraph.kt) must be in ENTRY_POINTS.
#   - AndroidManifest.xml declares entry points the JVM call-graph never sees
#     (BroadcastReceivers, Services, Application class).
#
# CONTEXT: ../../README.md  (guardrails)
# CASE STUDY: ../../docs/FAKE_WORK_AUDIT.md (Rust origin; pattern is universal)

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"
MANIFEST_PATH="${MANIFEST_PATH:-app/src/main/AndroidManifest.xml}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "kotlin-android.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find awk sort; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "kotlin-android.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

# Determine scan root for source files
if [ -z "$SRC_GLOBS" ]; then
    if   [ -d "app/src/main/java" ];   then SCAN_ROOT="app/src/main/java"
    elif [ -d "app/src/main/kotlin" ]; then SCAN_ROOT="app/src/main/kotlin"
    elif [ -d "src/main/kotlin" ];     then SCAN_ROOT="src/main/kotlin"
    else SCAN_ROOT="."
    fi
else
    SCAN_ROOT="$SRC_GLOBS"
fi

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
TMP_REACH=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS" "$TMP_REACH"' EXIT

# ─── Source file collection (production only) ─────────────────────────
find "$SCAN_ROOT" -type f -name '*.kt' 2>/dev/null | \
    grep -vE '(/src/test/|/src/androidTest/|/build/|/test/|/tests/|/androidTest/|Test\.kt$|Tests\.kt$|Spec\.kt$|TestKoin\.kt$)' > "$TMP_FILES"

if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

# ─── Reachability sources ─────────────────────────────────────────────
# A symbol is "reachable" if it appears in any of:
# 1. Each ENTRY_POINT verbatim file (small set, fast-path check)
# 2. AndroidManifest.xml (manifest-declared components)
# 3. Auto-discovered Koin module files (Koin DSL pattern: `module {`)
# 4. ANY production source file under SCAN_ROOT, excluding the defining file
#    (broad fallback — catches any production reference)
{
    for ep in $ENTRY_POINTS; do
        [ -f "$ep" ] && echo "$ep"
    done
    [ -f "$MANIFEST_PATH" ] && echo "$MANIFEST_PATH"
    grep -lE '^[[:space:]]*(val|fun)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=?[[:space:]]*module[[:space:]]*\{' "$SCAN_ROOT" -r --include='*.kt' 2>/dev/null
} | sort -u > "$TMP_REACH"

# ─── Public top-level symbol extraction ───────────────────────────────
# Match column-0 declarations only (skips inner / member declarations).
# Reject lines starting with private/internal/protected.
# Class-like:  (data|sealed|abstract|open|inline|value|annotation|enum)? (class|object|interface)  Name
# Function:    fun  name(
# Composable:  preceded line is `@Composable` — picked up as plain `fun` (we don't track annotation context, all top-level fun is captured)
# Properties (val/var) and typealiases are NOT tracked (low fake-work risk).
while IFS= read -r file; do
    awk -v file="$file" '
        # naive block-comment tracking
        /\/\*/ { in_comment=1 }
        /\*\// { in_comment=0; next }
        in_comment { next }
        # explicit non-public visibility — skip
        /^[[:space:]]*(private|internal|protected)[[:space:]]/ { next }
        # class / object / interface / enum class / sealed class / sealed interface — column 0 only
        /^(public[[:space:]]+)?(abstract[[:space:]]+|open[[:space:]]+|final[[:space:]]+|sealed[[:space:]]+|data[[:space:]]+|inline[[:space:]]+|value[[:space:]]+|annotation[[:space:]]+|enum[[:space:]]+)*(class|object|interface)[[:space:]]+[A-Z][A-Za-z0-9_]*/ {
            line = $0
            sub(/^(public[[:space:]]+)?(abstract[[:space:]]+|open[[:space:]]+|final[[:space:]]+|sealed[[:space:]]+|data[[:space:]]+|inline[[:space:]]+|value[[:space:]]+|annotation[[:space:]]+|enum[[:space:]]+)*(class|object|interface)[[:space:]]+/, "", line)
            sub(/[^A-Za-z0-9_].*$/, "", line)
            if (length(line) > 0 && line ~ /^[A-Z]/) print file ":" NR ":" line
            next
        }
        # top-level fun (column 0, no leading whitespace)
        /^fun[[:space:]]+[a-zA-Z_][A-Za-z0-9_]*[[:space:]]*\(/ {
            line = $0
            sub(/^fun[[:space:]]+/, "", line)
            sub(/[[:space:]]*\(.*$/, "", line)
            sub(/<.*$/, "", line)
            if (length(line) > 0) print file ":" NR ":" line
            next
        }
        # top-level fun with explicit receiver: `fun Foo.bar(...)` — track `bar`
        /^fun[[:space:]]+[A-Z][A-Za-z0-9_<>?,. ]*\.[a-zA-Z_][A-Za-z0-9_]*[[:space:]]*\(/ {
            line = $0
            sub(/^fun[[:space:]]+[^.]+\./, "", line)
            sub(/[[:space:]]*\(.*$/, "", line)
            if (length(line) > 0) print file ":" NR ":" line
            next
        }
    ' "$file"
done < "$TMP_FILES" > "$TMP_SYMS"

[ ! -s "$TMP_SYMS" ] && exit 0

# ─── Skip-list: infrastructure / generated names that grep-reachability
#    can never sensibly verify. Project-specific names (your Application
#    class, your top-level NavGraph composable) belong in ENTRY_POINTS —
#    they get exempted by file, not by name, so they don't need to be here.
SKIP_REGEX='^(R|BuildConfig|Companion|invoke|Color|Theme|Type|Typography|Shapes|String|Int|Long|Boolean|Float|Double|Char|Byte|Unit|Any|Nothing)$'

# ─── Reachability check ───────────────────────────────────────────────
while IFS= read -r line; do
    [ -z "$line" ] && continue
    file=$(echo "$line" | awk -F: '{print $1}')
    # symbol = third field onward, joined back if pathological colons
    symbol=$(echo "$line" | awk -F: '{
        s = $3
        for (i = 4; i <= NF; i++) s = s ":" $i
        print s
    }')

    # Filter out infrastructure names
    if echo "$symbol" | grep -qE "$SKIP_REGEX"; then
        continue
    fi

    # If the file IS one of the entry-points, the symbol is trivially reachable
    is_entry_point=0
    for ep in $ENTRY_POINTS; do
        if [ "$file" = "$ep" ]; then
            is_entry_point=1
            break
        fi
    done
    [ "$is_entry_point" = "1" ] && continue

    # Fast path: check curated reach list (entry-points + manifest + Koin modules)
    found=0
    while IFS= read -r reach_file; do
        [ -z "$reach_file" ] && continue
        [ "$reach_file" = "$file" ] && continue
        if grep -qwF "$symbol" "$reach_file" 2>/dev/null; then
            found=1
            break
        fi
    done < "$TMP_REACH"

    # Slow path: any production .kt file under SCAN_ROOT (excluding the defining file).
    # Fixed-string + word-boundary is faster and avoids regex injection from symbol names.
    if [ "$found" = "0" ]; then
        # grep -rlwF: list files matching as fixed-string word — short-circuits per file.
        # We exclude the defining file by checking the result list manually.
        match_file=$(grep -rlwF -- "$symbol" --include='*.kt' "$SCAN_ROOT" 2>/dev/null | grep -vF "$file" | head -1)
        [ -n "$match_file" ] && found=1
    fi

    [ "$found" = "0" ] && echo "$line"
done < "$TMP_SYMS"
