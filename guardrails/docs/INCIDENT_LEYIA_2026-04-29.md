# LeyIA same-day MVP audit — 2026-04-29

> **Status: post-incident retrospective.** This document captures a single 8-hour session in which an operator + Claude prepared the LeyIA platform for an MVP customer demo, found ~53 production bugs in the process, and synthesized the underlying patterns into 4 new guardrail defense classes (filed upstream as `bot202102/devcontainer-claude-lite#24`).
>
> **Why read this**: it complements `bot202102/devcontainer-claude-lite/guardrails/docs/FAKE_WORK_AUDIT.md` (the GainShield case from 2026-04-17) by documenting a SECOND independent incident with a structurally different fault profile. Together they argue that "fake-work" is not a single class — it's at least five.

---

## Setting

- **Product**: LeyIA — cognitive workbench for chatting with Peruvian fiscal/penal expedientes (legal case files)
- **Stack**: backend `expediente-processor` (Python 3.13, FastAPI, FastMCP, LangChain v1, Qdrant, Mistral OCR, DeepSeek V4); frontend `leyia` (React 19, Vite 7, TypeScript 5, rc-dock)
- **Hosts**: 2 VPSes — VPS A (Cloudflare tunnel, Caddy, frontend bundle); VPS B (backend + Qdrant/Redis/MinIO). No staging.
- **Demo target**: lawyer uploads a 12-tomo carpeta fiscal, processes via OCR + boundary detection + embeddings, chats with the document via DeepSeek V4 Flash with citations.
- **Test fixture used during the day**: `CARPETA FISCAL 02-2024 TOMO I.pdf` (200 pages) + `CARPETA FISCAL 02-2024 TOMO II ok.pdf` (201 pages), both ingested under the same `case_id` to verify multi-tomo support.

## Timeline (UTC)

| Time | Event |
|------|-------|
| 09:00 | Operator pulls latest origin/main on VPS B; applies my queue of fixes from prior session. |
| 09:30 | First demo upload — 17KB PDF (`reporte-pastoral-odres-nuevos-...`). Works. |
| 12:48 | First TOMO I upload (30MB, 200 pages). Pipeline runs OCR → boundaries → index → **dies at 300s `asyncio.wait_for` cap before Qdrant ingest**. CF returns 502 because container restarted mid-request. (`expediente-processor#453`, `#454` filed) |
| 12:55 | Workaround: bump pipeline timeout 300s → 1800s. Reprocess from MinIO. Data lands. |
| 13:30 | Frontend image-preview component fires `/v2/pages/.../image` ~15× per second, trips backend rate limit (600 rpm). 429 cascades. (`leyia#456` filed; rate limit raised 600→3000 as band-aid). |
| 13:46 | TOMO II upload. Pipeline starts, but Qdrant container hits Linux default `nofile=1024` cap ("Too many open files"); RocksDB segment writes fail; pipeline hangs after 50/109 subdocs ingested. **Container reports `healthy` for 11 minutes** (because `/health` is a static `{status: "healthy"}` JSON, never exercises Qdrant). (`expediente-processor#454` ulimit fix; `expediente-processor#455` umbrella for the architectural lesson). |
| 14:00 | Switch Docker `HEALTHCHECK` to a new deep `/ready` that pings Qdrant + Redis + MinIO with 1s timeout each in parallel. Container would have flipped to `unhealthy` in ~90s instead of lying for 11 min. |
| 14:30 | Multi-tomo case loaded in workbench; lawyer tildas one subdoc, **a different subdoc auto-tildas**. Same `subdoc_id=1` in tomo I and tomo II. (`expediente-processor#459`, `leyia#459` filed.) |
| 14:50 | "Ficha del Expediente" panel renders garbage: `Subdocumentos: 0`, `Tomos: 14` (actually showing `doc_types.length`), `Total páginas: 201` (collision-collapsed). Six panel-binding bugs filed. |
| 15:00 | First pattern-search agent dispatched (vs panel-by-panel): finds **37 contract drifts** between hand-written `rest.ts` interfaces and live OpenAPI spec. (`leyia#471`) |
| 15:30 | Second pattern-search agent: storage write/read continuity audit. Finds **6 layers** with split-brain or orphan storage (OCR cache, FTS5 partial, folio_mappings empty, LLM page-meta cache, case_entities, document_aliases). |
| 16:00 | Third pattern-search agent: identity-collision + silent-failure audit. Finds the **single worst bug of the day**: `create_point_id` UUID5 seed `(expediente_id, page_number)` produces colliding IDs for page 1 of tomo 1 and page 1 of tomo 2 → **second ingest silently overwrites the first point in Qdrant**. Data loss undetectable at search time. (`expediente-processor#471`) |
| 16:45 | Operator pauses the bug-finding loop. "Antes de seguir avanzando como locos consolidemos lo que aprendimos." |
| 17:00+ | Consolidation: write 4 new guardrail skills (`verify-contract`, `verify-storage`, `verify-identity`, `verify-honest-failure`); session report (this document); upstream PR to `devcontainer-claude-lite`. |

## What was filed

| Repo | Bugs / features | Examples |
|------|-----------------|----------|
| `bot202102/leyia` | ~25 issues | #449 (codegen), #459 (subdoc selection collision), #460 (Ficha panel bindings), #461-#469 (8 panel-specific binding bugs), #471 (37-drift umbrella), #472 (audit consolidation) |
| `bot202102/expediente-processor` | ~25 issues | #453 (sync /complete → CF 524), #454 (Qdrant nofile), #455 (architectural umbrella), #456 (OCR cache split), #458 (FTS5 dual-write), #459 (subdoc UUID expose), #460 (page collision), #461 (juzgado extractor), #466 (folio_mappings empty), #469 (identity umbrella), #470 (silent failure umbrella), #471 (UUID5 collision data loss), #475 (storage drift umbrella), #476-#478 (3 new storage drifts) |
| `bot202102/devcontainer-claude-lite` | 1 proposal | #24 (4 new guardrail skills) |

## The 4 fault patterns synthesized

Caught **0 of these** by the existing `verify-done` skill / `integration-gate.sh` hook. The current guardrails detect "ghost code" — a public symbol exported but never imported. Today's bugs are structurally different: every symbol IS imported, every test passes, every deploy succeeds — the failures are in the **continuity between layers**.

### Pattern 1 — Cross-layer contract drift

A consumer's hand-written types diverge from the producer's emitted schema. Symbol is wired correctly; field names / shapes / envelopes / casings diverge silently. Reads return `undefined`, no error fires.

| Subkind | Today's count | Example |
|---------|---------------|---------|
| Naming (camelCase/snake_case) | 18 | `subdoc_id` read vs `subdocId` emitted |
| Missing backend field | 9 | `role` on `EntityNode`, `keyTerms` on `PageContextResponse` |
| Shape (flat vs nested) | 5 | `topEntities` flat vs `entities.byType` nested |
| Endpoint 404 | 3 | `/access/subdocs/mine` doesn't exist |
| Type mismatch | 2 | `parts_count: integer` vs `part_size: bytes` |

**Root cause**: no single source of truth. Backend Pydantic models, OpenAPI emission, and frontend TypeScript interfaces drift independently. Backend ships a rename, frontend never finds out, browser silently shows blank values.

**Defense proposed**: `verify-contract` skill — diff producer schema vs consumer types field-by-field before claiming "endpoint integration done".

### Pattern 2 — Storage write/read continuity

A storage layer (cache directory, SQLite table, Qdrant collection) is read in code but written nowhere — OR written by one path and read from a different path (split-brain).

| Layer | Reads from | Writes to | Drift |
|-------|------------|-----------|-------|
| OCR cache | `cache/ocr_results/{md5}.json` (legacy) | SQLite `cache.db` (DT-129) | Half-migrated |
| LLM page-meta | `glob cache/llm_analysis/*.json` (legacy) | SQLite `cache.db` (DT-129) | Same migration, second layer |
| FTS5 index | `data/fts5_index.db` | partial — silent `except: pass` | 5/174 missing |
| folio_mappings | `data/folio_mappings.db` | NOTHING | 0 rows ever |
| case_entities | `entity_tools`, `relationship_tools`, `page_insight_tools` | only via interactive MCP, never from ingest | Feature dark for every doc |
| document_aliases | Qdrant payload writes | only via manual MCP `set_alias` | PDF human names never reach payloads |

**Root cause**: a refactor (DT-129 SQLite cache backend) added the producer side but didn't update all consumer call-sites. Symbols and signatures look right; the data path is broken end-to-end. Tests pass because tests use fixtures pre-populated by the same path.

**Defense proposed**: `verify-storage` skill — for every storage layer, ≥1 producer reachable from ingest entry-point + live exercise check (after a fixture run, layer is non-empty).

### Pattern 3 — Identity-as-display confusion

A field is treated as canonical identity (cache key, React `key=`, Set/Map key, deterministic UUID seed) AND as a per-scope display number. When records grow beyond one scope, identity collisions cause silent data corruption.

| Instance | Where | Symptom |
|----------|-------|---------|
| `create_point_id` UUID5 seed | `expediente_id + page_number` | Multi-tomo collision → second ingest overwrites first point in Qdrant. **Silent data loss at ingest, undetectable at search.** |
| `subdoc_id` as React key | leyia panels | Tildar one subdoc tildas another |
| `set(page_number)` for `total_pages` | `case_summary_stub` | 201 vs real 400 (pages from different tomos collapse) |
| Timeline dedup map keyed on `subdoc_id` | timeline aggregator | One tomo's entries clobber the other's |

**Root cause**: per-scope identifiers (per-PDF, per-tomo) used as global keys. Industry-standard fix is well known (UUID for identity, sequential int for display) but easy to forget when prototyping a single-PDF case and only later expanding to multi-PDF.

**Defense proposed**: `verify-identity` skill — for any field used as React key / Set key / cache key / UUID seed, verify it's marked unique at schema level OR all scoping dimensions are present in the key.

### Pattern 4 — Silent failure / soft-fallback

Code returns `[]` / `None` / `{success: False, ...}` followed by neither raise, nor log.error, nor user-visible error code. Caller sees garbage as success.

| Instance | What it returns | What user/agent sees |
|----------|-----------------|----------------------|
| Agent on missing LLM config | `"No encontré documentos relevantes"` | Same as legitimate empty result |
| `hybrid_search` on `ImportError` | crude scroll results | Same shape as full hybrid, no `degraded=True` |
| `/health` pre-fix | `{status: "healthy"}` | Returns 200 with Qdrant dead |
| OCR cache miss | empty list of pages | "no se encontró el PDF" buried in 502 |
| Pipeline async task crash | logged-only | `/uploads/complete` still returned `success=true` |

**Root cause**: defensive coding gone too far. Returning empty data on any error shape feels safer than raising — until the error becomes invisible.

**Defense proposed**: `verify-honest-failure` skill — for each `return [] / return None / return {"success": False}`, verify it's followed by raise / log.error / propagation. Extends the closed `silencer-pattern` issue (#12 in upstream) which only covered empty-catch shapes.

## Numbers

| Metric | Value |
|--------|-------|
| Issues filed today | ~53 (across 3 repos) |
| Bugs caught by existing guardrails | 0 |
| Hours of debugging | ~8 |
| Container rebuilds | 5 |
| Backend commits pushed | 7 |
| Workbench bundle redeploys | 1 (via Sonnet sub-agent) |
| Sub-agents launched | 9 (Sonnet model, total ~30 min wall-clock) |
| Worst single bug | `create_point_id` UUID5 collision → silent data loss in Qdrant (`expediente-processor#471`) |

## Lessons

1. **"Tests green, deploys clean" doesn't mean "works in production"** when production has scale (multi-tomo, real customers, real load). Today: 205 hypothetical passing tests, 0 caught the multi-tomo collision because every test is single-PDF.

2. **`/health` lying is the worst kind of monitoring failure.** Container reported healthy for 11 minutes during full Qdrant outage. The fix (deep `/ready`) is 80 lines of code and would have been valuable from day 1. The reason it wasn't there: liveness vs readiness distinction is a Kubernetes idiom, and Docker only checks `HEALTHCHECK`. The pattern wasn't transferred.

3. **Identity ≠ display** is REST API design 101 but every prototype gets it wrong. Stripe, GitHub, every modern API enforces UUID for identity + sequential for display. We had `point_id` (UUID, perfect) and `subdoc_id` (sequential, per-tomo) — and exposed only the sequential one.

4. **Pattern-search agents beat panel-by-panel audits 10:1.** Two agents auditing 4 panels each took ~12 min and found 8 bugs. Three pattern-search agents auditing the WHOLE codebase took ~25 min and found 47 bugs (including the data-loss one), an order of magnitude more efficient.

5. **Document the SECOND incident, not just the first.** GainShield (2026-04-17, written up in `FAKE_WORK_AUDIT.md`) was 60% ghost code. LeyIA (this) is 0% ghost code, 100% cross-layer drift. Two incidents = two patterns = case for two distinct guardrail families.

## What's preserved beyond this session

- **Code committed and pushed**: 7 commits on branch `fix/llm-deepseek-v4-migration-2026-04-29`, PR `expediente-processor#435` updated.
- **Issues filed in GitHub**: ~53 with `owner:prod` / `owner:dev` labels (see [`bot202102/leyia` open](https://github.com/bot202102/leyia/issues?q=is%3Aopen+label%3A%22owner%3Aprod%22%2C%22owner%3Adev%22) and [`bot202102/expediente-processor` open](https://github.com/bot202102/expediente-processor/issues?q=is%3Aopen)).
- **Upstream proposal**: `bot202102/devcontainer-claude-lite#24` — 4 new guardrail skills.
- **Skill drafts**: in `/tmp/skill_drafts/` (this session); landing as PR to upstream.
- **CLAUDE.md updates**: both `expediente-processor/CLAUDE.md` and `leyia/CLAUDE.md` now have a "Workflow — ownership and deploy" section explaining `owner:prod` / `owner:dev`.
- **Memory** (Claude's own persistent memory): the 4 patterns + prod/dev workflow + LeyIA architecture saved as memory entries for future sessions.

## What was NOT preserved (and why)

- The exact prompts used to dispatch the 9 sub-agents — recoverable from the conversation transcript at `~/.claude/projects/-home-centeno/<session-id>.jsonl` if needed.
- The intermediate diagnostic outputs (curl responses, Qdrant scroll results) — ephemeral by design; the issues capture the conclusions.
- The page-citation / folio architecture conversation — captured in `expediente-processor#466` body and the umbrella `#455`, but no formal design doc yet (see future work below).

## Future work (open at end of session)

- Implement page-citation drill-down architecture (3-piece plan: populate folio_mappings during ingest, add `drill_down_pages(subdoc_id, query)` agent tool, add no-match similarity threshold)
- The `owner:prod` queue: `#451` rename, `#456` OCR cache, `#457` qdrant client pin, `#458` FTS5 dual-write, `#459` UUID exposure, `#460` page count collision, `#461` juzgado extractor, `#463` date in SubdocItem, `#466` folio mappings, `#471` UUID5 seed fix (CRITICAL), `#476` LLM cache split, `#477` AnnotationPipeline call from ingest, `#478` document_aliases population
- Frontend dev's queue: ~20 `owner:dev` issues primarily about contract drift, panel rebinding, and the new "Cargas y procesamiento" view (`leyia#457`)
- Land the 4 new skills upstream and adopt them locally on this repo
- Add a load test fixture (12-tomo synthetic carpeta) to CI to prevent regression of the multi-tomo bugs

---

*Document maintained by: operator + Claude. Update when adopting any of the 4 proposed defenses.*
