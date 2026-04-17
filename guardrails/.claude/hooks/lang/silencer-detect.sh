#!/usr/bin/env bash
# silencer-detect.sh — find empty-or-comment-only catch blocks that wrap
# production data calls (await fetch, db.query, sql`…`, imported query
# helpers). This is the "silencer" anti-pattern that turns a loud 500
# into silent empty state and hides bugs for weeks.
#
# Motivating incident: a consumer repo had this SSR pattern in an Astro
# page:
#
#   try {
#     pastorDashboardData = await getPastorDashboardData(tenantId);
#   } catch {
#     // Fallback — client will fetch
#   }
#
# The DB query underneath was broken (raw SQL used the wrong table name)
# and threw. The `catch {}` swallowed the error. The client then fetched
# the same broken endpoint, also got 500, and showed an empty state. 14+
# users treated "dashboard empty" as "no data yet" for 11 days.
#
# Mechanism:
#   1. For each .ts/.tsx/.astro file, state-machine awk scans line-by-line.
#   2. Enter state "in try": when a line matches `try {` or `try\s*$`.
#   3. Within try: note if body contains an await-DB indicator
#      (`await`, `.query(`, `sql\``, `fetch(`, import from `@/lib/db/queries`).
#   4. Exit try + enter state "catch": when a line matches
#      `\}\s*catch(\s*\(…\))?\s*{`.
#   5. Within catch: check if body is empty (only closing `}`) or contains
#      only comment lines (`//`, `/*`, `*`, `*/`).
#   6. Flag: if body-has-db AND catch-is-silent → emit
#      `file:try-line:silencer`.
#
# Contract: stdout = one finding per line as `file:line:silencer`.
# Exit 0 always (non-blocking).
#
# Config:
#   SRC_GLOBS              — dirs to scan (default: src)
#   SILENCER_DB_INDICATORS — regex of patterns that count as "production
#                            data call" inside try body. Default covers
#                            common drizzle/fetch usage.

set -u

SRC_GLOBS="${SRC_GLOBS:-src}"
# Default DB-indicator regex (awk syntax). Covers:
#   - any `await` (most common)
#   - `.query(`  (pg client, knex, etc.)
#   - `sql\``   (drizzle / postgres-js template tag)
#   - `fetch(`  (HTTP)
#   - `.request(` / `.send(`  (fetch-like clients)
#   - `import from '@/lib/db/`  (imports signal DB access)
DB_INDICATOR_RE="${SILENCER_DB_INDICATORS:-await|\\.query\\(|sql\\\`|fetch\\(|\\.request\\(|\\.send\\(|lib/db/queries}"

EXCLUDE_RE='(/node_modules/|/dist/|/build/|/\.next/|/\.astro/|\.test\.|\.spec\.|/tests?/|/__tests__/|/__mocks__/|\.d\.ts$)'

for bin in grep find awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "silencer-detect.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

[ ! -d "$SRC_GLOBS" ] && exit 0

find $SRC_GLOBS -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.astro' \) \
    2>/dev/null \
    | grep -vE "$EXCLUDE_RE" \
    | while IFS= read -r f; do
        awk -v file="$f" -v DB_RE="$DB_INDICATOR_RE" '
            BEGIN {
                state = 0        # 0=outside, 1=inside try, 2=inside catch (post-open)
                try_line = 0
                has_db = 0
            }

            # State 0: look for `try {` (same line) or `try\s*$` (brace next line)
            state == 0 && /^[[:space:]]*try[[:space:]]*(\{|$)/ {
                state = 1
                try_line = NR
                has_db = 0
                next
            }

            # State 1: inside try body, collect DB signals. Stop at `} catch ... {`.
            state == 1 {
                # Check for DB indicator on this line
                if ($0 ~ DB_RE) has_db = 1

                # Check for catch opening on this line.
                # Accept: `} catch {`, `} catch (e) {`, `} catch (e: unknown) {`,
                # or the catch keyword on its own line following a prior `}`.
                if ($0 ~ /^[[:space:]]*\}[[:space:]]*catch([[:space:]]*\([^)]*\))?[[:space:]]*\{[[:space:]]*(\/\/.*)?$/) {
                    state = 2
                    catch_empty = 1     # empty until proven otherwise
                    next
                }
                # Also catch the split form: `} catch (e) {` on its own followed by newline
                next
            }

            # State 2: inside catch body. Classify each line.
            state == 2 {
                # Closing brace alone → end of catch
                if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
                    if (has_db && catch_empty) {
                        print file ":" try_line ":silenced-data-call"
                    }
                    state = 0
                    next
                }
                # Comment-only line → still "empty" catch semantically
                if ($0 ~ /^[[:space:]]*(\/\/|\*|\/\*|\*\/)/) {
                    next
                }
                # Blank line → ignore
                if ($0 ~ /^[[:space:]]*$/) {
                    next
                }
                # Anything else = real code in catch → NOT silenced
                catch_empty = 0
                # Continue until closing brace to avoid re-triggering
            }
        ' "$f"
    done

exit 0
