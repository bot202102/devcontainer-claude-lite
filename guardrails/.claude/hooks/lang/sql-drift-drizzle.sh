#!/usr/bin/env bash
# sql-drift-drizzle.sh — detect raw SQL that references a table name which
# does NOT exist in the Drizzle schema. This is a NEW defense class: it
# catches the pattern where raw SQL (sql`FROM foo` templates or literal
# `client.query('INSERT INTO foo ...')` strings) uses a JS variable name
# as the table name instead of the real DB table name.
#
# Motivating incident: a consumer repo had a 11-day prod outage because
# `pgTable('group_members', ...)` is exported as `smallGroupMembers` in
# JS, and a developer copied-and-adapted a drizzle query into a raw SQL
# template literal using `FROM small_group_members` — the old name from
# a previous rename. Drizzle ORM queries resolve via the JS var, raw SQL
# does not. The TS compiler sees only strings.
#
# Mechanism:
#   1. Extract every `pgTable('<name>', ...)` declaration from the schema
#      directory (default: src/lib/db/schema/). These are the ACTUAL DB
#      table names.
#   2. Scan source files (excluding tests + schema/) for raw SQL keyword +
#      identifier patterns: `FROM <id>`, `JOIN <id>`, `INTO <id>`,
#      `UPDATE <id>`, `DELETE FROM <id>`. Collect every referenced name.
#   3. Any referenced name NOT in the actual-tables set is flagged as a
#      "drift" — the query will fail in production with `relation does
#      not exist`.
#   4. Skip names known-good: system catalogs (pg_*), information_schema,
#      common CTEs / subquery aliases. The skip list is configurable via
#      SQL_DRIFT_KNOWN_TABLES env var (space-separated).
#
# Contract:
#   - stdout: one finding per line as `file:line:<referenced-name>`
#   - exit 0 always (non-blocking by default; callers combine with a gate)
#
# Config:
#   SCHEMA_GLOBS    — directories/globs that contain pgTable() declarations.
#                     Default: `src/lib/db/schema src/db/schema drizzle/schema`
#   SRC_GLOBS       — directories to scan for raw SQL. Default: `src`
#   SQL_DRIFT_KNOWN_TABLES
#                   — space-separated list of names to treat as valid even
#                     if absent from pgTable() (e.g. views, CTEs, extension
#                     tables). Skips system catalogs automatically.

set -u

SCHEMA_GLOBS="${SCHEMA_GLOBS:-src/lib/db/schema src/db/schema drizzle/schema}"
SRC_GLOBS="${SRC_GLOBS:-src}"
EXTRA_KNOWN="${SQL_DRIFT_KNOWN_TABLES:-}"

for bin in grep find awk sort tr; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "sql-drift-drizzle.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

TMP_TABLES=$(mktemp)
TMP_REFS=$(mktemp)
TMP_DIFF=$(mktemp)
trap 'rm -f "$TMP_TABLES" "$TMP_REFS" "$TMP_DIFF"' EXIT

# ─── 1. Collect actual DB table names from pgTable('<name>', ...) ─────

FOUND_SCHEMA=0
for dir in $SCHEMA_GLOBS; do
    [ -d "$dir" ] || continue
    FOUND_SCHEMA=1
    find "$dir" -type f -name '*.ts' 2>/dev/null
done > "${TMP_TABLES}.files"

if [ "$FOUND_SCHEMA" = "0" ]; then
    # No schema dir → nothing to check against. Silent pass.
    exit 0
fi

while IFS= read -r f; do
    # pgTable('name', ...) or pgTable("name", ...). Multi-line friendly —
    # grep reassembles then sed extracts the first string arg. POSIX-portable.
    tr '\n' ' ' < "$f" \
        | grep -oE "pgTable[[:space:]]*\([[:space:]]*['\"][^'\"]+['\"]" \
        | sed -E "s/pgTable[[:space:]]*\\([[:space:]]*['\"]([^'\"]+)['\"].*/\\1/"
done < "${TMP_TABLES}.files" | sort -u > "$TMP_TABLES"

if [ ! -s "$TMP_TABLES" ]; then
    echo "sql-drift-drizzle.sh: found schema dir(s) but no pgTable() declarations in $SCHEMA_GLOBS" >&2
    exit 0
fi

# ─── 2. Extract raw-SQL table references from source files ────────────

# Known-good names we accept without a matching pgTable() — system tables,
# extension tables, common subquery aliases. User can add via env var.
KNOWN_SYSTEM="pg_type pg_namespace pg_catalog pg_class pg_attribute pg_constraint pg_index information_schema __drizzle_migrations generate_series unnest jsonb_array_elements json_array_elements string_to_array regexp_split_to_table"
# Common CTE / subquery aliases.
KNOWN_ALIASES="t sub cte tmp temp a b c x y z result row rows data src dst prev curr new old"
# SQL keywords that our greedy regex picks up after a FROM/JOIN/INTO/UPDATE
# when they appear in prose, comments, or other SQL syntax. These are NOT
# tables — they're language primitives.
SQL_KEYWORDS="select insert values returning order group having limit offset where with set on off when then else end null true false current default primary foreign references cascade restrict enum json jsonb text varchar int integer bigint smallint serial bigserial boolean bool uuid timestamp timestamptz date time interval decimal numeric real float double char bytea array asc desc nulls first last all any some exists in between like ilike not and or is isnull notnull unique check constraint table column view index trigger function procedure returns language plpgsql sql"
# English prose words that sneak in from comments. Short list; extend via env.
PROSE_WORDS="the a an this that these those it its as at by for from of to into onto out over under after before during since until while whether which who whom whose what where when why how being done run runs running one two three four five six seven eight nine ten individual drizzle node lucide google url personevents the server failed existing ocr video flat horizontal invitation choices selected label enrolled dni headers parts per search array group line purchase consolidation last_activity now"

{
    echo "$KNOWN_SYSTEM"
    echo "$KNOWN_ALIASES"
    echo "$SQL_KEYWORDS"
    echo "$PROSE_WORDS"
    echo "$EXTRA_KNOWN"
    cat "$TMP_TABLES"
} | tr ' ' '\n' | awk 'NF' | sort -u > "${TMP_TABLES}.all"

EXCLUDE_RE='(/node_modules/|/dist/|/build/|/\.next/|/\.astro/|\.test\.|\.spec\.|/tests?/|/__tests__/|/__mocks__/|\.d\.ts$|/schema/)'

# Find source files to scan — narrow to those that actually contain a raw-SQL
# vehicle (drizzle `sql\`` template or a `.query(` call). This excludes 95%+
# of React components and prevents false positives on English prose like
# "import from X".
find $SRC_GLOBS -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.astro' \) \
    2>/dev/null \
    | grep -vE "$EXCLUDE_RE" \
    | while IFS= read -r f; do
        if grep -qE "sql\`|\.query\(" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done > "${TMP_REFS}.files"

while IFS= read -r f; do
    # Per-file CTE harvest: `WITH <name> AS (` (and the comma-separated extras
    # in multi-CTE templates). Names collected here are added to the known
    # set so `FROM <cte-name>` does not trigger drift.
    # Harvest CTE names from this file. Handles:
    #   WITH name AS (
    #   WITH RECURSIVE name AS (
    #   , name AS (   (for multi-CTE lists)
    cte_names=$(tr '\n' ' ' < "$f" 2>/dev/null \
        | grep -oE "(WITH[[:space:]]+(RECURSIVE[[:space:]]+)?|,[[:space:]]+)[a-z_][a-z0-9_]*[[:space:]]+AS[[:space:]]*\(" \
        | sed -E 's/.*[[:space:]]+([a-z_][a-z0-9_]*)[[:space:]]+AS.*/\1/' \
        | tr '\n' '|' | sed 's/|$//')

    # Use grep -oE to extract each keyword+identifier pair per line, then
    # awk to drop the keyword and lowercase the table name. POSIX-portable.
    # Skip lines with SQL function syntax that contains FROM:
    # EXTRACT(X FROM Y), CAST(X FROM Y), SUBSTRING(X FROM Y), POSITION(X IN Y).
    grep -nEi '(\bFROM\b|\bJOIN\b|\bINTO\b|\bUPDATE\b)[[:space:]]+[a-z_][a-z0-9_]*' "$f" 2>/dev/null \
        | grep -viE '\b(EXTRACT|CAST|SUBSTRING|POSITION|OVERLAY|TRIM)\s*\(' \
        | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' \
        | awk -v file="$f" -v cte="$cte_names" -F: '
            BEGIN {
                # Parse the per-file CTE list into a skip set
                if (cte != "") {
                    n_cte = split(cte, cte_arr, "|")
                    for (i = 1; i <= n_cte; i++) skip_cte[cte_arr[i]] = 1
                }
            }
            {
                line = $1
                rest = $0
                sub(/^[0-9]+:/, "", rest)
                while (1) {
                    n = match(rest, /[Ff][Rr][Oo][Mm][ \t]+[A-Za-z_][A-Za-z0-9_]*|[Jj][Oo][Ii][Nn][ \t]+[A-Za-z_][A-Za-z0-9_]*|[Ii][Nn][Tt][Oo][ \t]+[A-Za-z_][A-Za-z0-9_]*|[Uu][Pp][Dd][Aa][Tt][Ee][ \t]+[A-Za-z_][A-Za-z0-9_]*/)
                    if (!n) break
                    m = substr(rest, RSTART, RLENGTH)
                    sub(/^[A-Za-z]+[ \t]+/, "", m)
                    lc = tolower(m)
                    # Skip if identifier is a CTE declared in this same file
                    if (!(lc in skip_cte)) {
                        print file ":" line ":" lc
                    }
                    rest = substr(rest, RSTART + RLENGTH)
                }
            }
        '
done < "${TMP_REFS}.files" > "$TMP_REFS"

# ─── 3. Diff: references NOT in actual-tables set ─────────────────────

# Extract just the name column from refs, compare to tables
awk -F: '{print $NF}' "$TMP_REFS" | sort -u > "${TMP_REFS}.names"

# Set difference: referenced names not in known-good set
# Both files are already sort -u
UNKNOWN_NAMES=$(comm -23 "${TMP_REFS}.names" "${TMP_TABLES}.all" 2>/dev/null || true)

if [ -z "$UNKNOWN_NAMES" ]; then
    exit 0
fi

# For each unknown name, print the file:line:name hits
echo "$UNKNOWN_NAMES" | while IFS= read -r name; do
    [ -z "$name" ] && continue
    grep -E ":${name}$" "$TMP_REFS" || true
done | sort -u

exit 0
