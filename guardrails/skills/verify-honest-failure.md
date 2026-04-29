---
name: verify-honest-failure
description: Use BEFORE claiming an error path, fallback behavior, health check, or degraded-mode handler is correct, safe, or observable. Runs the 5-question honest-failure protocol with REAL command output — empty-return enumeration, signal audit (raise/log.error/user-facing code), agent tool handling, health check external-dep exercise, degraded-mode flag — and returns evidence-or-failure. Catches the soft-fallback pattern: code returns [] / None / {success: False} without raising, without logging at error level, and without propagating to user-visible state, so the caller treats silence as success. If you are about to write "errors are handled", "fallback is safe", "health check passes", "degraded mode works" — invoke this skill first.
---

# verify-honest-failure — observable error signals before claiming safe fallback

## Why this exists

Error handling code frequently compiles, runs, and is considered "done" while being functionally invisible. The function catches an exception, returns `[]` or `None`, and the caller iterates over an empty list as if the operation succeeded. The user sees empty results. No exception propagates. No log line at `ERROR` level. No `success=False` on the response. The system appears healthy.

This pattern is distinct from the empty-catch shape that existing ghost checks detect (`except: pass`, `catch (e) {}`). The soft-fallback looks like defensive programming:

```python
result = search(query)
if not result:         # could be ImportError, timeout, or legitimately 0 results
    return []          # caller cannot distinguish the two
```

Four production incidents from `expediente-processor` (2026-04-29 audit):

- **#470** (umbrella) + **#473** — The LeyIA agent emits the literal string `"no encontré documentos"` whether the LLM call crashed, the vector search returned an error, or the search legitimately returned zero results. The user receives the same message for a broken system and for a real empty result set.
- **#474** — `hybrid_search()` catches an `ImportError` (dense-search library not available) and silently degrades to a crude scroll fallback. No `degraded=True` on the response. No `log.warning`. The caller assumes hybrid search ran; the returned results are of systematically lower quality.
- **health check** (pre-audit) — The `/health` endpoint returned HTTP 200 with `{"status": "ok"}` by constructing the dict literally, without connecting to Qdrant or MinIO. An outage on either dependency was invisible to the health probe.

This skill is the **signal-honesty evidence layer**: you invoke it when you claim error handling, fallback behavior, or health checking is correct. It verifies that failures produce observable signals — not silence dressed as success.

## When to invoke

Invoke BEFORE any of these outputs:

- A message containing "errors are handled", "fallback is safe", "graceful degradation", "health check passes", "the agent surfaces errors", "empty results are handled"
- A PR that adds or modifies an `except` / `catch` / `.catch()` block in a production path
- A PR that adds a health check endpoint or changes an existing one
- A PR that adds a search fallback or a degraded-mode code path
- A PR that modifies agent tool result handling
- Closing a GitHub issue that involved error handling, fallback behavior, or observability

If the PR only adds a `try/except` inside a test, skip this skill.

## How to invoke

1. Enumerate every soft-fallback return in the production code paths changed (check 1).
2. For each: verify at least one honest signal follows (check 2).
3. If the feature includes an agent tool: verify agent propagates `success=False` (check 3).
4. If the feature includes a health check: verify it actually exercises external deps (check 4).
5. If the feature includes a degraded-mode path: verify `degraded=True` on response (check 5).
6. Write a single "Honest-failure verdict" block with results per site.
7. If ANY check is FAIL, **do not claim errors are handled**. Fix the signal or mark `wip:`.

## The 5 checks

`$MODULE` = the module containing the error handling. `$FUNC` = the function being verified.

### 1. Enumerate soft-fallback returns in production paths

> Find every `return []`, `return None`, `return {}`, `return {"success": False, ...}` that is NOT immediately preceded by a raise, `log.error`, or user-facing error propagation.

```bash
# Python: soft-fallback returns inside except or if-not blocks
python3 - << 'EOF'
import ast, sys

TARGET = "mcp_server/"  # adjust
import os, pathlib

patterns = ("return []", "return None", "return {}", 'return {"success": False')

for py_file in pathlib.Path(TARGET).rglob("*.py"):
    if "test" in str(py_file) or "spec" in str(py_file):
        continue
    src = py_file.read_text()
    for lineno, line in enumerate(src.splitlines(), 1):
        stripped = line.strip()
        for pat in patterns:
            if stripped.startswith(pat[:12]) and "raise" not in stripped:
                # Check 3 lines before for log.error / raise / propagation
                prev = src.splitlines()[max(0, lineno-4):lineno-1]
                has_signal = any(
                    "log.error" in p or "log.warning" in p or "raise " in p
                    or "logger.error" in p or ".error(" in p
                    for p in prev
                )
                if not has_signal:
                    print(f"{py_file}:{lineno}: CANDIDATE — {stripped[:80]}")
EOF

# TypeScript / Node: return null / return [] without preceding throw or console.error
grep -rn "return \[\]\|return null\|return undefined\|return { success: false" \
  apps/web/src/ mcp_server/ --include='*.ts' --include='*.tsx' \
  | grep -v 'test\|spec' \
  | head -30
```

This gives you a candidate list. Not every candidate is a bug — some have a signal two lines up. Verify each one manually in context. FAIL if any candidate in a critical path (search, ingest, chat, health) has no signal in the preceding 5 lines and no signal in its caller.

### 2. Signal audit — raise, log.error, or user-facing error code

> For each candidate from check 1: what signal does the failure produce?

For each candidate, answer all three questions:

| Candidate | Raises exception? | Logs at error/warn level? | Returns user-visible error code or field? |
|---|---|---|---|
| hybrid_search():ImportError → return [] | No | No | No (response indistinguishable from 0 results) |
| search():timeout → return None | No | log.warning added ✓ | No — caller treats None as empty |
| ingest():OCR fail → return {"success": False} | No | No | Yes IF caller checks .success |

```bash
# Python: check what logging surrounds a known soft-return
grep -n -B10 "return \[\]" mcp_server/services/search.py \
  | grep -E "log\.|raise|logger\.|\.error\(|\.warning\("

# Check what the caller does with a None/empty return
grep -n "hybrid_search\|search_pages" mcp_server/ -r --include='*.py' \
  | grep -v 'def hybrid_search\|def search_pages\|test' \
  | head -10
# Then read those call sites:
# Does the caller check `if result is None`? Does it propagate an error to the user?
```

PASS per candidate if: it raises an exception (caller handles or propagates), OR it logs at `log.error` / `log.warning` AND the caller propagates the emptiness as an error to the user, OR the response has a structured `degraded=True` / `success=False` that the caller surfaces. FAIL if the only outcome is silence — the empty return propagates to the user as a normal response.

### 3. Agent tool result handling

> When an agent calls a tool and `result.success == False`, does the agent surface that to the user rather than continuing as if the tool succeeded?

```python
# Python: grep for tool-call result handling in agent code
grep -n "result\.\|tool_result\.\|response\." mcp_server/agents/ -r --include='*.py' \
  | grep -iE "success|error|is_error" | head -20

# Check the agent response assembly for tool failures
grep -n -A15 "def query_case\|def run_agent\|async def agent" \
  mcp_server/agents/leyia_agent.py 2>/dev/null | head -60
```

Look for the pattern:

```python
# BAD: agent continues as if tool succeeded
tool_result = await call_tool("search", args)
# (no check for tool_result.success or tool_result.is_error)
context = tool_result.content  # silent: could be empty / error message

# GOOD: agent surfaces failure explicitly
tool_result = await call_tool("search", args)
if tool_result.is_error or not tool_result.content:
    return AgentResponse(
        answer="La búsqueda falló: " + tool_result.error_message,
        success=False,
        error_code="SEARCH_FAILED"
    )
```

Also check: does the agent distinguish "search returned 0 results" from "search threw an error"? If both produce the same user-facing message (e.g., `"no encontré documentos"` in #473), the user cannot tell whether the system is broken or the query has no results.

```bash
# Check for the specific pattern from #473: one message for both outcomes
grep -n "no encontré\|no se encontr\|no results\|0 results\|empty" \
  mcp_server/agents/ -r --include='*.py' | head -10
# If the same string appears in both the error branch and the empty-result branch, it's a FAIL
```

PASS if agent response distinguishes error (`success=False` + specific error message) from empty result (`success=True`, `result_count=0`). FAIL if both produce identical user output.

### 4. Health check external-dep exercise

> The health endpoint must actually connect to each declared external dependency. Returning a hardcoded dict is a security theater health check.

```bash
# Run the health endpoint against the real server
curl -s http://localhost:18082/health | python3 -m json.tool

# What we expect to see:
# {
#   "status": "ok",                    ← or "degraded"
#   "qdrant": {"status": "ok", "collections": 2},
#   "minio": {"status": "ok"},
#   "sqlite": {"status": "ok", "tables": 6}
# }
```

```python
# Read the health handler and verify it makes real calls
python3 - << 'EOF'
import ast, pathlib

health_file = pathlib.Path("mcp_server/routes/health.py")
if not health_file.exists():
    # Try alternate locations
    import subprocess
    result = subprocess.run(
        ["grep", "-rn", "def health\|@router.get.*health\|@app.get.*health",
         "mcp_server/", "--include=*.py"],
        capture_output=True, text=True
    )
    print(result.stdout[:500])
else:
    src = health_file.read_text()
    # Look for actual connection calls
    calls = [l.strip() for l in src.splitlines()
             if any(kw in l for kw in ["get_collections", "list_buckets", "ping",
                                        "execute", "connect", "qdrant", "minio", "redis"])]
    if not calls:
        print("FAIL: health handler makes no external calls")
    else:
        print("Potential external calls found:")
        for c in calls: print(" ", c)
EOF

# Kill a dependency and verify health reports degraded (not 200 OK)
# (only run if you have a test/dev instance, not prod)
# docker stop leyia-qdrant
# curl -s http://localhost:18082/health | python3 -m json.tool
# docker start leyia-qdrant
```

PASS if the health handler contains ≥1 live call per declared dependency AND returns a non-200 status code (or `{"status": "degraded"}`) when a dependency is unavailable. FAIL if the handler constructs the response dict without calling any external service — it is hardcoded, not a health check.

### 5. Degraded-mode flag in response

> When a search or processing path silently degrades (falls back to a simpler algorithm due to a missing dep, timeout, or partial failure), the response must carry an explicit `degraded=True` field so the caller can handle or surface it.

```bash
# Find degraded-mode branches
grep -rn "except ImportError\|except.*Timeout\|except.*Connection\|fallback\|degrad" \
  mcp_server/ --include='*.py' | grep -v 'test' | head -20

# For each: does the fallback response include a degraded signal?
grep -n -A20 "except ImportError" mcp_server/services/search.py 2>/dev/null | head -30
```

Look for the pattern:

```python
# BAD: silent degradation (this was #474)
try:
    results = hybrid_search(query, dense_model=embed)
except ImportError:
    results = crude_scroll(query)   # no degraded=True, no warning
return results

# GOOD: honest degradation
try:
    results = hybrid_search(query, dense_model=embed)
    degraded = False
except ImportError as e:
    log.warning("hybrid_search unavailable (%s), falling back to scroll", e)
    results = crude_scroll(query)
    degraded = True
return SearchResponse(results=results, degraded=degraded,
                      degraded_reason="dense model unavailable" if degraded else None)
```

PASS if every fallback branch in a production search/processing path:
1. Logs at `warning` level with the reason
2. Sets a `degraded` field (or equivalent) on the response
3. The caller or response schema exposes that field to the client

FAIL if any fallback branch is silent — no log, no flag, same response shape as the full-quality path.

## Verdict format

```
Honest-failure verdict for expediente-processor search + agent:

  Candidates from check 1: 4 soft-return sites in production paths

  Site: hybrid_search() except ImportError → return []
    2. signal-audit:     FAIL — no raise, no log.warning, response indistinguishable
                                from legitimate 0-result search
    5. degraded-flag:    FAIL — no degraded=True, caller assumes full-quality results

  Site: query_case agent — tool_result not checked
    3. agent-tool:       FAIL — agent emits "no encontré documentos" for both
                                LLM error and genuine empty result; no success=False
                                on error path

  Site: /health endpoint
    4. health-check:     FAIL — handler returns {"status": "ok"} without calling
                                qdrant.get_collections() or minio.list_buckets();
                                hardcoded dict, not a live probe

  Site: ingest() OCR failure → log.error("ocr failed") + return {"success": False}
    2. signal-audit:     PASS — log.error present; caller checks .success and returns
                                HTTP 500 to client

Verdict: NOT DONE. 3 of 4 sites fail. Fix:
  - hybrid_search: add log.warning + degraded=True to fallback branch
  - agent: add result.is_error check; return distinct error vs empty-result messages
  - /health: call each external dep; return 503 if any fails
Commit prefix: wip:
```

Or on full pass:

```
Honest-failure verdict for expediente-processor search + agent:

  1. enum:         4 soft-return sites found
  2. signal:       PASS — all 4 log at warning/error AND caller propagates to user
  3. agent:        PASS — is_error checked; error message distinct from empty result
  4. health:       PASS — /health calls qdrant.get_collections() + minio.list_buckets();
                          returns 503 with {"status": "degraded", "qdrant": "unreachable"}
                          when Qdrant container stopped (verified by stopping container)
  5. degraded:     PASS — hybrid fallback sets degraded=True; response schema includes field

Verdict: HONEST FAILURES VERIFIED. All error paths produce observable signals.
         Proceeding with feat: commit.
```

## Interaction with verify-done

`verify-done` check 6 (runtime trace) confirms the error handling code ran. It does not verify what signal the code produced. `verify-honest-failure` check 2 verifies that the signal was observable — a `log.warning` that the caller ignores is not the same as an error that surfaces to the user. Both skills must pass before claiming error handling is complete.

## Interaction with existing ghost checks

The existing ghost-check pattern (`.claude/hooks/integration-gate.sh`) catches the empty-catch shape: `except: pass`, `catch (e) {}`. This skill catches the distinct **soft-fallback shape**: the exception is handled, something is returned, but the return is structurally indistinguishable from a successful result. The ghost check will PASS on the #474 pattern; this skill catches it.

## When NOT to use

- Error handling in test-only code.
- Returning `[]` from a function where the caller is in the same module and explicitly handles the empty case with a raised exception or user-visible error.
- Exploring or reading code without a completion claim.

If a PR adds any `except` / `catch` in a production path, or modifies a health check, or adds a fallback mode — run this skill.

## Relation to CLAUDE.md Definition of Done

This skill enforces DoD check 2 (evidence of execution) for the error branch: not just that the handler ran, but that its execution produced a signal the user or operator can act on. An error handler that executes silently and returns `[]` has the same operational outcome as no error handler — the operator cannot detect the failure, cannot alert, cannot recover.

## References

- `guardrails/README.md` — layered defense overview
- `guardrails/docs/FAKE_WORK_AUDIT.md` — real case (GainShield, 60% fake-work despite 205 green tests)
- `guardrails/docs/DEFINITION_OF_DONE.md` — norm block for CLAUDE.md
- `bot202102/expediente-processor#470` — umbrella: soft-fallback pattern across multiple paths
- `bot202102/expediente-processor#473` — agent emits same message for error vs empty result
- `bot202102/expediente-processor#474` — hybrid_search ImportError silently degrades to scroll, no signal
- `bot202102/expediente-processor#477` — /health returned 200 with hardcoded dict; Qdrant outage invisible
- `.claude/hooks/integration-gate.sh` — mechanical Stop gate (complementary layer)
