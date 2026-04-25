---
name: verify-done
description: Use BEFORE claiming a feature/module/endpoint/adapter is complete, done, finished, implemented, ready, working, or wired. Runs the 6-question Definition of Done protocol with REAL command output — dependency tree, entry-point grep, endpoint exercise, log trace, placeholder scan — and returns evidence-or-failure. Complements `.claude/hooks/integration-gate.sh` (mechanical Stop hook) by giving the agent a way to self-check with evidence BEFORE the hard gate fires. If you are about to write "it works", "implemented", "all tests pass", "ready to ship", or equivalent — invoke this skill first.
---

# verify-done — self-check before claiming completion

## Why this exists

`.claude/hooks/integration-gate.sh` (Stop hook, exit 2) is a **mechanical cinturón**: it blocks session end if new ghost symbols appeared vs baseline. It does NOT let you self-audit before trying to Stop. Result: you discover the failure only when you try to close the turn, context already assembled around a wrong claim.

This skill is the **declarative-with-evidence layer**: you invoke it when you *think* you're done. It runs real commands and returns what works / what doesn't. You see the truth before writing "it works" to the user or to memory.

## When to invoke

Invoke BEFORE any of these outputs:

- A message to the user containing "done", "complete", "implemented", "working", "ready", "shipped", "wired", "functional", "fixed", "resolved"
- A `git commit -m "feat: ..."` or `feat(...)` — feat prefix is a completion claim
- A memory write reporting a milestone complete
- A PR description saying a feature is ready for review
- Closing a GitHub issue with `gh issue close`

If none of the above apply, you don't need this skill. Doing a refactor, exploring, reading code — skip it.

## How to invoke

1. Read `.claude/hooks/project.conf` to get `LANG` and `ENTRY_POINTS` (required).
2. For each of the 6 checks below, run the language-appropriate command and paste the ACTUAL output. Not a summary. Not "looks good." The raw stdout/stderr.
3. Classify each check: PASS (green), FAIL (red), N/A (explain why), CANNOT RUN (missing tool / env — explain).
4. Write a single "DoD verdict" block with the results + the symbol/feature name being verified.
5. If ANY check is FAIL, **do not claim done**. Fix it or mark the work `wip:` / `scaffold:`.

## The 6 checks

Adapt the command to the project's `LANG` (from `project.conf`). Symbol `$SYM` = the public symbol you claim is done. Feature path `$FEATURE` = human-readable name (endpoint URL, module name, etc.).

### 1. Dependency-tree reachability

> The binary actually pulls the module.

| LANG | Command |
|---|---|
| rust | `cargo tree -p <main-crate> \| grep <new-module-crate>` |
| python | `python -c "import ast; tree = ast.parse(open('$ENTRY_POINTS').read()); print([n for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)])" \| grep <new-module>` |
| node | `pnpm exec tsc --listFiles --project apps/backend/tsconfig.json 2>/dev/null \| grep <new-module-path>` (or use `node --trace-dependencies`) |
| astro | `grep -r "from.*<new-module>" src/pages/ src/middleware.ts astro.config.*` |
| go | `go list -deps ./cmd/<app> \| grep <new-package>` |
| java | `grep -r "import.*<NewClass>" src/main/java/` |
| kotlin-android | One of: `grep -rw "<NewClass>" $ENTRY_POINTS` (entry-points reachability) — OR — `grep -rE "(single\|factory\|viewModel)\s*\{[^}]*<NewClass>" app/src/main/java/.../core/di/` (Koin module registration) — OR — `grep "<NewClass>" app/src/main/AndroidManifest.xml` (manifest-declared) — OR — `grep -rwl "<NewClass>" app/src/main/java/ \| grep -v "<defining-file>"` (any other production caller) |

PASS if ≥1 match. FAIL if 0 matches — the "module is wired" claim is false.

### 2. Binary/server mentions the feature

> If the feature is toggleable, the entry-point advertises it.

| LANG | Command |
|---|---|
| rust | `<binary> --help \| grep -i <feature>` |
| python | `python -m <pkg> --help \| grep -i <feature>` |
| node | `pnpm <script> --help 2>&1 \| grep -i <feature>` or `curl -s http://localhost:3000/<feature-route>` |
| astro / fastify / express | `curl -s http://localhost:<port>/<route>` — expect non-placeholder JSON |
| go | `<binary> --help \| grep -i <feature>` |
| java | `java -jar target/<jar> --help \| grep -i <feature>` |
| kotlin-android | App has no `--help` flag. Verify via: (a) `adb shell am start -n <applicationId>/.MainActivity` then exercise the feature in the UI and `adb logcat -s <TAG>:V \| grep <unique-string>`; OR (b) for backend-touching features, `curl <prod-api>/...` shows non-placeholder JSON. If neither is feasible (no device, no JDK in sandbox), say "Check 2 CANNOT RUN: no device/emulator available" — do not fake. |

PASS if the feature is referenced AND the response is not `{}`, `{"note": "..."}`, `{"status": "pending"}`, `"Coming soon"`, `"available when connected"`. FAIL if placeholder.

### 3. Call-site outside tests

> Some production file references the symbol.

```bash
grep -r "\b$SYM\b" <src-dirs> --include='*.<ext>' \
  | grep -v -E '(__tests__|\.test\.|\.spec\.|/tests?/|/lab/|/examples/)' \
  | wc -l
```

Where `<src-dirs>` = production source roots (e.g. `apps/backend/src packages/shared/src mcp-servers` — NOT `e2e/`, NOT `tests/`). PASS if ≥1. FAIL if 0 — it's a ghost.

### 4. Call-graph trace from entry-point

> Walk from the entry-point to the symbol.

Open `ENTRY_POINTS`. Does it reference the symbol directly OR a function that references the symbol? Trace 2-3 hops. Paste the chain:

```
apps/backend/src/index.ts
  → buildApp() in apps/backend/src/app.ts:12
    → fastify.register(ttsRoutes) in apps/backend/src/app.ts:45
      → ttsRoutes declares POST /api/tts invoking generateAudio
        → generateAudio in apps/backend/src/services/tts/generator.ts:$SYM
```

PASS if you can write the chain with actual file:line refs. FAIL if a hop is missing or behind a never-enabled flag.

### 5. No placeholder ghosts in diff

> The diff doesn't include the known fake-work patterns.

```bash
git diff <base-branch>...HEAD --unified=0 \
  | grep -iE 'TODO|FIXME|placeholder|not.yet.implemented|DEV SKIPPED|available when connected|Coming soon|mock data|not.yet.wired|\[0u8;\s*\d+\]|changeme|bytes\(\[0\]' \
  | head -20
```

Include any `EXTRA_GHOST_PATTERNS` from `project.conf`. PASS if 0 matches in added lines (`+` prefix). FAIL if any match — rewrite the diff.

### 6. Runtime trace of the new code path

> Actually run it once. Capture log lines that prove the new code executed.

```bash
# Start the binary (dev mode OK)
pnpm dev:backend &
sleep 3

# Exercise the feature
curl -X POST http://localhost:3000/<route> -H 'Content-Type: application/json' -d '<payload>'

# Grep the log for a line that ONLY the new code could emit
# (log must include a unique identifier added in this change — module name, feature flag, etc.)
grep '<unique-string-from-new-code>' <log-file>

# Stop
kill %1
```

PASS if ≥1 matching log line with timestamp within the last exercise. FAIL if the grep is empty — code compiled but never ran.

If you CANNOT run the binary (no DB, no secrets, sandboxed env), say so explicitly: "Check 6 CANNOT RUN: backend requires POSTGRES_URL not set in this env." Do not fake this one. An honest "cannot verify" is better than a dishonest "verified".

## Verdict format

Write a single fenced block before your completion claim:

```
DoD verdict for <feature/symbol>:
  1. deps-tree-reachable: PASS — cargo tree shows gainshield-m14 in gainshield-cli tree
  2. binary-mentions:     PASS — gainshield-cli --help shows --enable-m14
  3. grep-outside-tests:  PASS — 3 matches in crates/gainshield-cli/src/main.rs
  4. call-graph-trace:    PASS — main → FeedbackEngine::new → enable_m14_adapters (src/main.rs:47)
  5. no-placeholders:     PASS — 0 matches in git diff main...HEAD
  6. runtime-trace:       PASS — log line "m14: frame 0 processed" in ~/.gainshield/debug.log @ 14:22:07

Verdict: DONE. Evidence above. Proceeding with feat: commit.
```

Or if any check fails:

```
DoD verdict for <feature>:
  1. deps-tree-reachable: PASS
  2. binary-mentions:     PASS
  3. grep-outside-tests:  FAIL — 0 matches in production code (only in tests/)
  4-6. skipped (1 prerequisite failure)

Verdict: NOT DONE. ProximityAdapter has no call-site in gainshield-cli.
Action: wire it from main.rs, or delete if the feature was scoped out.
Commit prefix: wip: or scaffold:
```

## Interaction with the Stop hook

`integration-gate.sh` will ALSO run at Stop. If verify-done said PASS but the Stop hook blocks, one of these is true:

- The skill output was optimistic (you didn't run check 3 or 6 for real).
- A new ghost appeared in a file you didn't look at (side-effect of the edit).

Either way: the Stop hook is ground truth. Re-run verify-done including the symbols the hook flagged, and fix.

## When NOT to use

- Routine refactors with no behavior change (no new public symbol, no new endpoint, no new feature claim).
- Exploring code, reading docs, answering questions.
- Fixing a typo or formatting.

If in doubt: did you add an `export` / `pub fn` / `func` / `public class`? Yes → verify-done. No → probably skip.

## Relation to CLAUDE.md Definition of Done

This skill is the ACTION version of the Definition of Done block in `CLAUDE.md`. The DoD is the norm; this skill is the procedure that enforces it with evidence. If CLAUDE.md is missing the DoD block, install it from `guardrails/docs/DEFINITION_OF_DONE.md`.

## References

- `guardrails/README.md` — layered defense overview
- `guardrails/docs/FAKE_WORK_AUDIT.md` — real case (GainShield, 60% fake-work despite 205 green tests)
- `guardrails/docs/DEFINITION_OF_DONE.md` — norm block for CLAUDE.md
- `.claude/hooks/integration-gate.sh` — mechanical Stop gate (complementary layer)
