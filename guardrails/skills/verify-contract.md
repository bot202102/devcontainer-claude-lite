---
name: verify-contract
description: Use BEFORE claiming a REST endpoint, gRPC method, GraphQL query, or any cross-layer data exchange is complete, integrated, wired, or compatible. Runs the 5-question contract-drift protocol with REAL command output — producer schema extraction, consumer type enumeration, field-by-field diff, endpoint path validation, live fixture exercise — and returns evidence-or-failure. The wiring may be correct (symbol exists, import resolves) yet values arrive as undefined because field names diverged between producer and consumer. If you are about to write "the frontend now reads X", "the API returns Y", "integration complete", or "fields mapped" — invoke this skill first.
---

# verify-contract — cross-layer field drift before claiming integration

## Why this exists

`verify-done` checks that a symbol is wired: the import resolves, the call-site exists, the function runs. It does NOT check that the **shape** of the data matches between producer and consumer. A handler can be wired and exercised while every response field resolves to `undefined` because the backend uses `snake_case` and the frontend reads `camelCase`, or because the backend wraps results in `{ data: { items: [...] } }` while the frontend destructures `{ items }` directly.

`bot202102/leyia#471` catalogued 37 of these drifts in one audit: 18 naming mismatches (camelCase vs snake_case), 9 fields present in consumer types but absent from backend responses, 5 shape divergences (flat vs nested envelope), 3 endpoint 404s (URL paths simply did not exist), 2 type mismatches (string vs number, array vs single value). Every one compiled, every one ran, zero surfaced an error at runtime — callers received `undefined` and rendered empty UI silently.

This skill is the **shape-evidence layer**: you invoke it when you claim two layers talk to each other. It diffs producer schema against consumer types and runs a live call that asserts field presence.

## When to invoke

Invoke BEFORE any of these outputs:

- A message containing "the frontend reads from the API", "fields mapped", "integration complete", "consumer updated", "schema aligned", "contract satisfied"
- A PR that adds or changes a request/response type on either side of a layer boundary
- A PR that adds a new endpoint or changes an existing one's URL, method, or response body
- A memory write reporting a backend-frontend integration milestone complete
- Closing a GitHub issue that involved cross-layer data

If both producer AND consumer are in the same module with no serialization boundary (e.g., two functions in the same Python file calling each other directly), skip this skill.

## How to invoke

1. Identify the **producer** (the side that serializes data: FastAPI model, Pydantic schema, protobuf definition, Prisma model, GraphQL resolver) and the **consumer** (the side that deserializes: TypeScript interface, Python TypedDict, Rust serde struct, Go struct with json tags).
2. For each of the 5 checks below, run the language-appropriate command and paste the ACTUAL output. Not a summary. The raw stdout.
3. Classify each check: PASS (green), FAIL (red), N/A (explain why), CANNOT RUN (missing tool / env — explain).
4. Write a single "Contract verdict" block with the results + the endpoint/schema being verified.
5. If ANY check is FAIL, **do not claim integration complete**. Fix the drift or mark `wip:` / `scaffold:`.

## The 5 checks

`$ENDPOINT` = the route path being verified (e.g. `/api/v1/cases/{case_id}/pages`). `$PRODUCER_MODEL` = the class/type that produces the response. `$CONSUMER_TYPE` = the class/type that reads it.

### 1. Producer schema available

> Extract the ground-truth shape from the producer side.

| LANG / STACK | Command |
|---|---|
| python (pydantic v2) | `python -c "from <module> import $PRODUCER_MODEL; import json; print(json.dumps($PRODUCER_MODEL.model_json_schema(), indent=2))"` |
| python (pydantic v1) | `python -c "from <module> import $PRODUCER_MODEL; import json; print(json.dumps($PRODUCER_MODEL.schema(), indent=2))"` |
| python (FastAPI) | `curl -s http://localhost:18082/openapi.json \| python3 -m json.tool \| grep -A 30 '"$PRODUCER_MODEL"'` |
| node / express | `curl -s http://localhost:<port>/api-docs/swagger.json \| jq '.components.schemas.$PRODUCER_MODEL'` |
| graphql | `pnpm exec tsx scripts/introspect.ts \| jq '.data.__type \| select(.name == "$PRODUCER_MODEL")'` |
| protobuf | `grep -A 20 'message $PRODUCER_MODEL' proto/<file>.proto` |
| rust (serde) | `grep -B2 -A 30 'struct $PRODUCER_MODEL' src/<path>.rs` |
| go | `grep -B2 -A 30 'type $PRODUCER_MODEL struct' <path>.go` |

PASS if you have a complete field list with types. FAIL if the schema file doesn't exist, the model can't be imported, or the OpenAPI spec returns 404 — the producer shape is unknown, no further checks are meaningful.

### 2. Consumer types enumerated

> Extract the types the consumer expects to receive.

| LANG / STACK | Command |
|---|---|
| typescript | `grep -A 30 'interface $CONSUMER_TYPE\|type $CONSUMER_TYPE' src/lib/api/types.ts apps/web/src/lib/api/types.ts` — check all files in `api/`, `types/`, `models/` |
| python (TypedDict) | `grep -B2 -A 20 'class $CONSUMER_TYPE(TypedDict)' <consumer-module>.py` |
| rust (serde Deserialize) | `grep -B2 -A 30 '#\[derive.*Deserialize\]' -A 0 src/<path>.rs \| grep -A 30 'struct $CONSUMER_TYPE'` |
| go | `grep -B2 -A 30 'type $CONSUMER_TYPE struct' <consumer-path>.go` |
| java | `grep -B2 -A 30 'class $CONSUMER_TYPE' src/main/java/<path>.java` |

PASS if the type exists and lists all expected fields. FAIL if no type exists (consumer uses `any`, untyped dict, or raw `JSON.parse`) — no type means no contract, which means silent drift is guaranteed.

### 3. Field-by-field diff — naming, type, shape, envelope, optionality

> Manually (or with `jq` / `python` diffing) compare every field in producer schema vs consumer type.

Build a table in your response:

| Field | Producer name | Consumer name | Producer type | Consumer type | Match? |
|---|---|---|---|---|---|
| example | `created_at` | `createdAt` | `string (ISO8601)` | `string` | NAMING DRIFT |
| example | `items` | `items` | `PageResponse[]` | `Page[]` | CHECK NESTED |
| example | `total_pages` | `totalPages` | `int` | `number` | OK |

Flag these specific drift classes:
- **Naming drift**: `snake_case` producer → `camelCase` consumer without explicit transform. Check if FastAPI/axum has a `by_alias=True` or `transform_response` middleware. Check if `axios` or `fetch` wrapper does camelization. If no transform exists, it's a FAIL.
- **Envelope drift**: producer returns `{ "data": { "items": [...] } }` but consumer destructures `{ items }`. Trace the exact nesting. FAIL if layers don't match.
- **Optionality drift**: producer has `Optional[str]` but consumer type has `field: string` (non-optional). FAIL — `undefined` will cause runtime errors.
- **Type drift**: producer returns `int` milliseconds, consumer reads it as a `Date` string. FAIL.
- **Missing field**: present in consumer type, absent from producer schema. FAIL — will always be `undefined`.

PASS only if every field matches (or a verified transform closes the gap). FAIL if any row is DRIFT or MISSING.

### 4. Endpoint path validity

> The URL path the consumer calls actually exists on the producer.

```bash
# FastAPI / uvicorn
curl -s http://localhost:18082/openapi.json \
  | python3 -c "import sys,json; spec=json.load(sys.stdin); print('\n'.join(spec['paths'].keys()))" \
  | grep -F "$ENDPOINT"

# Express / Fastify — list registered routes
# node: npx express-list-routes  (or custom router.stack walk)
curl -s http://localhost:<port>/api/__routes  # if you have a debug endpoint

# Django REST
python manage.py show_urls | grep "$ENDPOINT"

# gRPC — list services
grpc_cli ls localhost:<port>

# GraphQL — check type exists in schema
curl -s http://localhost:<port>/graphql -d '{"query":"{ __schema { queryType { fields { name } } } }"}' \
  | python3 -m json.tool | grep "$FIELD"
```

PASS if the endpoint path appears in the registered route list. FAIL if 0 matches — the consumer is calling a path that doesn't exist (this was 3 of the 37 drifts in #471).

### 5. Live exercise — assert field presence, not just HTTP 200

> Call the endpoint with a real fixture and assert that the fields the consumer reads are not undefined.

```bash
# Python: use a real test fixture
python3 - <<'EOF'
import httpx, sys

resp = httpx.get("http://localhost:18082/api/v1/cases/fixture-case-id/pages/1",
                  headers={"Authorization": "Bearer test-token"})
assert resp.status_code == 200, f"HTTP {resp.status_code}: {resp.text}"
body = resp.json()

# Assert every field the consumer type expects
required = ["page_number", "content_markdown", "folio", "image_url"]
missing = [f for f in required if body.get(f) is None]
if missing:
    print(f"FAIL: fields missing or None in response: {missing}", file=sys.stderr)
    print(f"Actual keys: {list(body.keys())}", file=sys.stderr)
    sys.exit(1)
print("PASS: all required fields present")
print({k: type(body[k]).__name__ for k in required})
EOF

# Node / TypeScript: same shape, using fetch + strict checks
node --input-type=module <<'EOF'
const resp = await fetch("http://localhost:3000/api/cases/fixture/pages/1",
  { headers: { Authorization: "Bearer test-token" } });
const body = await resp.json();
const required = ["pageNumber", "contentMarkdown", "folio", "imageUrl"];
const missing = required.filter(k => body[k] === undefined || body[k] === null);
if (missing.length) { console.error("FAIL fields:", missing); process.exit(1); }
console.log("PASS", Object.fromEntries(required.map(k => [k, typeof body[k]])));
EOF

# Rust: run the integration test that exercises the real HTTP layer
cargo test --test contract_$ENDPOINT_SLUG -- --nocapture 2>&1 | tail -20

# Go
go test ./internal/api/... -run TestContract_$ENDPOINT_SLUG -v 2>&1 | tail -20
```

PASS if all expected fields are present with non-null values. FAIL if any field is missing, null, or `undefined` — even if HTTP 200. An HTTP 200 with `undefined` fields is a silent contract failure, which is exactly what `#471` was full of.

If you CANNOT run the server (no secrets, sandboxed env), say so explicitly: "Check 5 CANNOT RUN: requires running expediente-processor with MINIO_URL not set in this env." Do not assert PASS without evidence.

## Verdict format

```
Contract verdict for <endpoint or schema pair>:
  Producer: <file:class>
  Consumer: <file:interface>

  1. producer-schema:    PASS — pydantic model_json_schema() returned 8 fields
  2. consumer-types:     PASS — TypeScript interface PageResponse found in types.ts with 8 fields
  3. field-diff:         FAIL — 3 naming drifts (snake→camel, no transform middleware found);
                                1 missing field (image_url on producer, imageUrl on consumer — absent from OpenAPI)
  4. endpoint-path:      PASS — /api/v1/cases/{case_id}/pages/{page_number} in openapi.json
  5. live-exercise:      FAIL — fields ["imageUrl"] missing/null in fixture response

Verdict: NOT DONE. 3 naming drifts + 1 missing field. Add camelCase alias to Pydantic model
         (model_config = ConfigDict(populate_by_name=True, alias_generator=to_camel)) and
         add image_url to PageResponse schema.
Action: fix producer schema, re-run check 3 and 5.
Commit prefix: wip:
```

Or on full pass:

```
Contract verdict for GET /api/v1/cases/{case_id}/pages/{page_number}:
  Producer: mcp_server/models/page.py:PageResponse
  Consumer: apps/web/src/lib/api/types.ts:PageResponse

  1. producer-schema:    PASS — 8 fields, all typed
  2. consumer-types:     PASS — 8 fields match
  3. field-diff:         PASS — all names match (FastAPI alias_generator=to_camel confirmed); envelope flat
  4. endpoint-path:      PASS — route registered in openapi.json
  5. live-exercise:      PASS — all 8 fields non-null in fixture response

Verdict: CONTRACT VERIFIED. Proceeding with feat: commit.
```

## Interaction with verify-done

`verify-done` check 6 (runtime trace) exercises the code path and looks for a log line. That check passes as soon as the handler runs. `verify-contract` check 5 goes further: it asserts that the **data coming back** matches the **shape the consumer expects**. Run both. A handler that runs and returns `{"items": null}` passes verify-done check 6 and fails verify-contract check 5.

## When NOT to use

- Both producer and consumer are in the same Python/Rust/Go module with no serialization step (direct function call, no JSON roundtrip).
- A refactor that renames an internal variable without changing the public schema.
- Reading docs or exploring code.

If a PR adds or changes a serialized boundary (HTTP, gRPC, GraphQL, message queue, file format) — run this skill.

## Relation to CLAUDE.md Definition of Done

This skill enforces the "evidence of execution" clause of the DoD: not just that the code ran, but that it produced the correct shape. DoD check 2 requires log output proving the code path executed; verify-contract check 5 requires that the data in that execution was structurally correct. Both must pass before `feat:` prefix.

## References

- `guardrails/README.md` — layered defense overview
- `guardrails/docs/FAKE_WORK_AUDIT.md` — real case (GainShield, 60% fake-work despite 205 green tests)
- `guardrails/docs/DEFINITION_OF_DONE.md` — norm block for CLAUDE.md
- `bot202102/leyia#471` — 37 contract drifts catalogued: 18 naming, 9 missing fields, 5 shape, 3 endpoint 404s, 2 type mismatches
- `.claude/hooks/integration-gate.sh` — mechanical Stop gate (complementary layer)
