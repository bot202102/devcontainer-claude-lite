---
name: verify-identity
description: Use BEFORE claiming a feature that uses any field as a cache key, React key prop, Set/Map/dict key, foreign key, UUID seed, or deduplication key is complete, correct, or collision-free. Runs the 5-question identity-scope protocol with REAL command output — key-use enumeration, schema-uniqueness assertion, scope-dimension completeness check, UUID/hash seed audit, collision regression — and returns evidence-or-failure. A field that is a per-scope sequential number (page 1 of tomo A, page 1 of tomo B) silently collides when used as a global identity, causing silent data overwrites or UI corruption that is invisible at search time. If you are about to write "IDs are stable", "keys are unique", "deduplication works", or "no collisions" — invoke this skill first.
---

# verify-identity — key scope completeness before claiming collision-free identity

## Why this exists

Fields that are per-scope sequential numbers become identity collisions the moment a second scope is added. The field remains valid as a display number within its scope; the bug emerges only when it is simultaneously used as a global key — as a UUID seed, a React `key=` prop, a Python `set` member, or a Qdrant point ID — without including the scoping dimension in the key.

Three production incidents from `expediente-processor` (2026-04-29 audit):

- **#471** — `create_point_id()` seeded a UUID5 from `(expediente_id, page_number)`. Multi-tomo expedientes (tomo A pages 1-200, tomo B pages 1-200) produced identical UUIDs for page 1 of tomo A and page 1 of tomo B. Qdrant upsert semantics silently **overwrite** on collision: the second ingest replaced the first tomo's embeddings. Data loss, undetectable at search time because queries returned results — just from the wrong tomo.
- **#459** (`leyia#459` + `expediente-processor#459`) — `subdoc_id` is a sequential index per tomo (`0, 1, 2, ...`). Used as a React `key=` prop across all tomos in a list. Identical keys across tomos caused React to reuse DOM nodes between list renders, producing stale UI.
- **#460** — page_number collected into a `set()` across all tomos to build a "unique pages" count. A set union of per-tomo page numbers collapses 201 + 201 pages into 201 because both tomos have pages 1-201. Reported page count: 201. Actual: 402.

This skill is the **key-scope evidence layer**: you invoke it when a field is used as an identifier in any context. It verifies that the identifier's uniqueness scope matches its usage scope.

## When to invoke

Invoke BEFORE any of these outputs:

- A message containing "IDs are stable", "keys are unique", "no collisions", "deduplication works", "point IDs are deterministic"
- A PR that adds or changes a UUID/hash generation function
- A PR that adds a React `key=` prop to a list item
- A PR that uses a field as a Python `set` member, `dict` key, or `Map` key for deduplication
- A PR that adds or changes a foreign key or cache key involving multi-scope data
- Closing a GitHub issue that involved identity, deduplication, or key stability

If the feature has only one scope (e.g., a single user's data, a flat table with a database-generated UUID PK) — run check 1 to confirm, then you may abbreviate checks 2-4.

## How to invoke

1. Enumerate every use of the field as a key (check 1).
2. For each use: verify uniqueness scope matches usage scope (check 2).
3. For UUID/hash seeds specifically: verify all scoping dimensions are present (check 3).
4. Check schema-level uniqueness constraints (check 4).
5. Run a collision regression with ≥2 scopes (check 5).
6. Write a single "Identity verdict" block with results per field.
7. If ANY check is FAIL, **do not claim collision-free**. Fix the scope gap or mark `wip:`.

## The 5 checks

`$FIELD` = the field being used as an identifier (e.g., `page_number`, `subdoc_id`). `$ENTITY` = the entity type (e.g., `Page`, `Subdoc`). `$SCOPE` = the declared scope of the field's uniqueness (e.g., "unique within a tomo", "unique within a case").

### 1. Enumerate every use of the field as a key

> Map every site where $FIELD is used in an identity role (not display, not sort, not filter — identity).

```bash
# React key prop
grep -rn "key={.*$FIELD\|key={\`.*$FIELD" apps/web/src/ --include='*.tsx' --include='*.ts'

# Python set member / dict key / dedup
grep -rn "\bset(\b\|\.add($FIELD\|{.*$FIELD.*for.*in\b" mcp_server/ --include='*.py' \
  | grep -v 'test\|spec'

# UUID / hash seed
grep -rn "uuid5\|uuid3\|UUID5\|UUID3\|hashlib\|uuid.uuid5" mcp_server/ --include='*.py' \
  | grep -v 'test'

# Qdrant point ID (typically a UUID derived from content)
grep -rn "PointStruct\|upsert\|upload_points" mcp_server/ --include='*.py' \
  | grep -B5 'id=' | grep -E 'id=|point_id'

# SQL foreign key / primary key usage
grep -rn "WHERE $FIELD\s*=\|JOIN.*ON.*$FIELD\|PRIMARY KEY.*$FIELD" mcp_server/ \
  --include='*.py' --include='*.sql'

# TypeScript Map / Set
grep -rn "new Map\|new Set\|\.set($FIELD\|\.has($FIELD" apps/web/src/ --include='*.ts' --include='*.tsx'

# Cache key composition
grep -rn "f\".*{$FIELD}\|f'.*{$FIELD}\|`.*\${$FIELD}" mcp_server/ --include='*.py' \
  | grep -iE 'cache|key|redis|bucket|path'
```

For each match, note:
- **Role**: UUID seed / React key / set member / dict key / cache key / FK / PK
- **File:line**
- **Scope declared**: what uniqueness does the field have by definition?
- **Usage scope**: what uniqueness does this role require?

FAIL if any role requires global uniqueness but $FIELD is only per-scope-unique.

### 2. Scope-dimension completeness for each key use

> For each identity use found in check 1: are ALL dimensions needed to make the key globally unique present?

Build a table:

| Use site | File:line | Field(s) in key | Required scope dimensions | Missing dimensions | Match? |
|---|---|---|---|---|---|
| UUID5 seed | vector_store.py:44 | `expediente_id, page_number` | case, tomo, page | `subdoc_id` (tomo ID) | COLLISION |
| React key | DocumentList.tsx:88 | `subdoc_id` | global list | `case_id, tomo_index` | COLLISION |
| set dedup | page_utils.py:12 | `page_number` | global set | `subdoc_id` | COLLAPSE |
| cache key | ocr_cache.py:7 | `case_id, page_number` | global cache | `subdoc_id` | COLLISION |

For the **UUID5 / UUID3 / hash** case, the full seed must include every dimension that distinguishes two records that could otherwise produce identical output. In the expediente model: a page is uniquely identified by `(case_id, subdoc_id, page_number)` — not `(case_id, page_number)`.

```bash
# Inspect the UUID seed function directly
grep -n "def create_point_id\|def make_point_id\|uuid\.uuid5\|uuid5" mcp_server/services/vector_store.py

# Show the full function body
python3 -c "
import ast, inspect
import importlib.util
spec = importlib.util.spec_from_file_location('m', 'mcp_server/services/vector_store.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
import inspect
print(inspect.getsource(mod.create_point_id))
"
```

PASS if every required dimension is present in the key composition. FAIL if any dimension is missing — collision is mathematically guaranteed.

### 3. Schema-level uniqueness constraint

> If a field is used as a unique identifier, the schema should enforce that uniqueness.

```python
# Pydantic: check for Field(..., unique=True) or discriminator
python3 -c "
from mcp_server.models.page import PageModel
import json
schema = PageModel.model_json_schema()
for name, props in schema.get('properties', {}).items():
    if props.get('uniqueItems') or name.endswith('_id'):
        print(f'{name}: {props}')
"
```

```sql
-- SQLite: check UNIQUE constraints on the field
python3 -c "
import sqlite3
conn = sqlite3.connect('db/expediente.db')
# Check table info and indexes
for row in conn.execute(\"SELECT sql FROM sqlite_master WHERE name='pages'\"):
    print(row[0])
for row in conn.execute(\"SELECT * FROM sqlite_master WHERE type='index' AND tbl_name='pages'\"):
    print(row)
"
```

```bash
# TypeScript: check if the key field has a @unique tag in JSDoc or is typed as a branded type
grep -n "unique\|Unique\|brand\|Brand\|Opaque" apps/web/src/lib/api/types.ts

# Qdrant: check payload index (not a uniqueness constraint, but reveals intended identity fields)
curl -s http://localhost:6333/collections/$COLLECTION \
  | python3 -m json.tool | grep -A5 'payload_schema'
```

PASS if the schema enforces uniqueness at the level the field's usage requires. FAIL if a field used as a global key has no uniqueness constraint — enforcement is missing, collisions will happen silently. N/A for React keys and Python set members (no schema enforcement possible there — check 2 is the gate).

### 4. UUID / hash seed audit

> For deterministic IDs (UUID5, UUID3, hashlib, snowflake, ULID with custom seed): verify the seed is as specific as possible.

```bash
# Find all deterministic ID generators
grep -rn "uuid\.uuid5\|uuid\.uuid3\|hashlib\.sha\|hashlib\.md5\|uuid5\|uuid3" \
  mcp_server/ --include='*.py' | grep -v 'test'

# For each: print the seed arguments used
python3 - <<'EOF'
import ast, sys

with open("mcp_server/services/vector_store.py") as f:
    tree = ast.parse(f.read())

for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func_name = ""
        if isinstance(node.func, ast.Attribute):
            func_name = node.func.attr
        elif isinstance(node.func, ast.Name):
            func_name = node.func.id
        if func_name in ("uuid5", "uuid3", "uuid4_from_str"):
            print(f"Line {node.lineno}: {ast.unparse(node)}")
EOF
```

For each UUID seed found, list:
- Arguments used in the seed
- Are all scoping dimensions present? (for pages: `case_id`, `subdoc_id` / tomo ID, `page_number`)
- Would two records from different scopes produce the same UUID?

PASS if no two logically distinct records can produce identical output. FAIL if any collision is theoretically possible — and remember: Qdrant upsert silently overwrites on collision, so the failure mode is data loss, not an error.

### 5. Collision regression — run ≥2 scopes through the same key-generation path

> Prove that keys from separate scopes don't collide.

```python
# Python: collision regression for point IDs
python3 - <<'EOF'
import uuid

# Simulate the current (potentially broken) key generator
def create_point_id_OLD(expediente_id: str, page_number: int) -> str:
    """The function as-is, without subdoc_id."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{expediente_id}:{page_number}"))

# Simulate the fixed generator
def create_point_id_FIXED(expediente_id: str, subdoc_id: str, page_number: int) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{expediente_id}:{subdoc_id}:{page_number}"))

expediente = "exp-001"
tomo_a, tomo_b = "subdoc-0", "subdoc-1"

# Page 1 of tomo A vs page 1 of tomo B
old_a = create_point_id_OLD(expediente, 1)
old_b = create_point_id_OLD(expediente, 1)
fix_a = create_point_id_FIXED(expediente, tomo_a, 1)
fix_b = create_point_id_FIXED(expediente, tomo_b, 1)

print("=== OLD (should collide) ===")
print(f"tomo_a page_1: {old_a}")
print(f"tomo_b page_1: {old_b}")
print(f"COLLISION: {old_a == old_b}")

print("\n=== FIXED (should not collide) ===")
print(f"tomo_a page_1: {fix_a}")
print(f"tomo_b page_1: {fix_b}")
print(f"COLLISION: {fix_a == fix_b}")
EOF
```

```typescript
// TypeScript: React key collision regression
// Run this in Node to verify key uniqueness across scopes
node --input-type=module << 'EOF'
const tomoA = [{ subdoc_id: 0 }, { subdoc_id: 1 }, { subdoc_id: 2 }];
const tomoB = [{ subdoc_id: 0 }, { subdoc_id: 1 }, { subdoc_id: 2 }];
const allSubdocs = [...tomoA, ...tomoB];

// OLD: key = subdoc_id  (per-tomo counter, will collide)
const keysOld = allSubdocs.map(s => String(s.subdoc_id));
const uniqueOld = new Set(keysOld);
console.log("OLD keys:", keysOld.join(", "));
console.log("OLD unique:", uniqueOld.size, "of", allSubdocs.length, "— COLLISION:", uniqueOld.size < allSubdocs.length);

// FIXED: key = `${tomo_index}-${subdoc_id}`
const keysFixed = [
  ...tomoA.map((s, i) => `0-${s.subdoc_id}`),
  ...tomoB.map((s, i) => `1-${s.subdoc_id}`)
];
const uniqueFixed = new Set(keysFixed);
console.log("\nFIXED keys:", keysFixed.join(", "));
console.log("FIXED unique:", uniqueFixed.size, "of", allSubdocs.length, "— COLLISION:", uniqueFixed.size < allSubdocs.length);
EOF
```

```python
# Set collapse regression (#460): page_number set across tomos
python3 - <<'EOF'
tomo_a_pages = set(range(1, 202))   # 201 pages
tomo_b_pages = set(range(1, 202))   # 201 pages

wrong = tomo_a_pages | tomo_b_pages   # union collapses to 201, not 402
correct = len(tomo_a_pages) + len(tomo_b_pages)

print(f"Wrong (set union): {len(wrong)} unique pages")
print(f"Correct (sum): {correct} total pages")
print(f"COLLAPSE: {len(wrong) != correct}")
EOF
```

PASS if `COLLISION: False` for the fixed generator AND `COLLISION: True` for the old one (to prove the test is meaningful). FAIL if the fixed generator still produces collisions. FAIL if the test only runs against one scope — a test that cannot detect the collision is not a collision test.

## Verdict format

```
Identity verdict for create_point_id (expediente-processor vector_store):

  Field: page_number
  Declared scope: unique within a tomo (subdoc)
  Identity uses enumerated:
    - UUID5 seed in vector_store.py:44 (requires global uniqueness)
    - Set dedup in page_utils.py:12 (requires global uniqueness)

  2. scope-completeness:   FAIL — UUID5 seed uses (expediente_id, page_number);
                                  missing subdoc_id. Pages 1-N from tomo A and tomo B
                                  produce identical UUIDs. Qdrant upsert will overwrite
                                  silently on second ingest.
  3. schema-constraint:    N/A — Qdrant has no uniqueness enforcement; key correctness
                                 is entirely the seed function's responsibility
  4. uuid-seed-audit:      FAIL — confirmed via AST parse: uuid.uuid5(NS, f"{eid}:{pn}")
                                  subdoc_id absent from seed
  5. collision-regression: FAIL — old generator: COLLISION True (page 1 tomo A == page 1 tomo B)
                                  fixed generator not yet written

Verdict: NOT DONE. UUID5 seed missing subdoc_id dimension. Every multi-tomo ingest has
         silently overwritten first-tomo embeddings since feature shipped.
Action: update create_point_id(expediente_id, subdoc_id, page_number), re-index all
        multi-tomo expedientes, re-run check 5.
Commit prefix: wip:
```

Or on full pass:

```
Identity verdict for create_point_id (expediente-processor vector_store):

  Field: page_number
  Identity uses: UUID5 seed (vector_store.py:44), set dedup (page_utils.py:12)

  2. scope-completeness:   PASS — seed uses (expediente_id, subdoc_id, page_number);
                                  all 3 scoping dimensions present
  3. schema-constraint:    N/A — Qdrant: no schema constraint; seed correctness verified by check 5
  4. uuid-seed-audit:      PASS — confirmed: uuid.uuid5(NS, f"{eid}:{sid}:{pn}")
  5. collision-regression: PASS — old_a == old_b: True (test detects collision)
                                  fix_a == fix_b: False (collision resolved)

Verdict: IDENTITY VERIFIED. No scope collisions. Proceeding with feat: commit.
```

## Interaction with verify-done

`verify-done` check 3 (grep outside tests) confirms the function is called from production code. It does not inspect the arguments. `verify-identity` check 2 inspects the arguments and verifies they cover the full uniqueness scope. A UUID seed function that is wired (verify-done PASS) and missing a scoping dimension (verify-identity FAIL) silently corrupts data — the worst failure mode because it produces no errors.

## When NOT to use

- Purely display-only fields (labels, descriptions) with no role as keys, seeds, or identifiers.
- Database-generated UUIDs (`uuid.uuid4()`, `gen_random_uuid()`) with no custom seed — their uniqueness is guaranteed by randomness, not scope.
- Exploring or reading code without a pending completion claim.

If a field is used as a React `key=`, Python `set` member, dict key, UUID seed, or cache key — run this skill.

## Relation to CLAUDE.md Definition of Done

This skill enforces the silent-corruption variant of DoD check 2 (evidence of execution). A Qdrant upsert with a colliding ID "executes" successfully and logs "upserted 1 point" — the DoD check passes. Verify-identity check 5 (collision regression) is the only gate that detects whether that upsert is overwriting a prior record.

## References

- `guardrails/README.md` — layered defense overview
- `guardrails/docs/FAKE_WORK_AUDIT.md` — real case (GainShield, 60% fake-work despite 205 green tests)
- `guardrails/docs/DEFINITION_OF_DONE.md` — norm block for CLAUDE.md
- `bot202102/expediente-processor#471` — UUID5 seed missing subdoc_id; silent Qdrant overwrite on multi-tomo ingest
- `bot202102/expediente-processor#459` / `bot202102/leyia#459` — subdoc_id used as React key; per-tomo counter collides in global list
- `bot202102/expediente-processor#460` — page_number set-union collapses 402 pages to 201
- `.claude/hooks/integration-gate.sh` — mechanical Stop gate (complementary layer)
