---
name: verify-storage
description: Use BEFORE claiming a cache layer, database table, file directory, vector collection, or any persistent storage is populated, working, seeded, or functional. Runs the 5-question storage-integrity protocol with REAL command output — layer enumeration, producer presence, producer reachability, live row/file count after fixture run, migration consistency — and returns evidence-or-failure. Two failure modes caught: orphan (table/dir/collection exists but no producer writes to it) and split-brain (write path Y was updated but read path X still points to old location). If you are about to write "data is persisted", "cache is populated", "table is seeded", "storage layer works", or equivalent — invoke this skill first.
---

# verify-storage — storage integrity before claiming data persistence

## Why this exists

A storage layer can be declared, migrated, schema-valid, and fully reachable — yet contain zero rows, because the producer that writes to it was never wired to the ingest pipeline. Or the write path was updated to a new key/table/directory, but the read path still references the old location. Both failure modes compile, pass static analysis, and survive unit tests that mock the storage layer. They only reveal themselves in production when queries return empty results or caches never warm.

Five real incidents from `expediente-processor` (2026-04-29 audit):

- **#456** — OCR cache: SQLite writer stores results keyed as `cache_ocr_{hash}`, but the reader looks for `{hash}.json` in a filesystem directory. Write and read never touched the same storage medium.
- **#458** — FTS5 full-text index: 5 of 174 documents silently skipped during indexing due to a swallowed exception in the batch loop. Index reported as "built" with 97% coverage gap invisible unless you count rows.
- **#466** — `folio_mappings` table: schema existed, migration ran, but the function that populates it (`build_folio_index`) was never called from the ingest entry point. Zero rows ever. All folio lookups silently fell back to linear scan.
- **#476** — LLM page-meta cache: same split-brain pattern as #456 affecting a second independent layer. Two separate features, same root cause.
- **#477** — `case_entities` table: schema valid, but `AnnotationPipeline.run()` was never invoked from the document ingest pipeline. Zero rows produced. Entity-based queries returned empty results silently.

This skill is the **write-path evidence layer**: you invoke it when you claim data is being stored or a cache is warm. It traces every storage layer to a live producer and then counts rows after a fixture run.

## When to invoke

Invoke BEFORE any of these outputs:

- A message containing "cache is populated", "table is seeded", "data is persisted", "storage layer works", "index built", "rows inserted", "files written"
- A PR that introduces a new table, collection, bucket, directory, or key-value namespace
- A PR that changes a write path (new key format, new table name, new file path) without auditing all read sites
- A memory write reporting that a persistence or caching layer is operational
- Closing a GitHub issue that involved data storage, caching, or indexing

If the code you're reviewing has no persistence at all (pure in-memory computation, no I/O) — skip this skill.

## How to invoke

1. Enumerate every storage layer the feature touches (step 1 below).
2. For each layer: run checks 2, 3, 4 in sequence. A FAIL on check 2 or 3 makes check 4 meaningless — mark those as skipped and fix first.
3. If ANY write path changed recently, run check 5.
4. Write a single "Storage verdict" block with results per layer.
5. If ANY check is FAIL, **do not claim data is persisted**. Fix the producer gap or mark `wip:`.

## The 5 checks

`$TABLE` = SQL table or FTS5 virtual table name. `$COLLECTION` = Qdrant collection. `$DIR` = filesystem cache directory. `$BUCKET` = MinIO/S3 bucket. `$KEY_PATTERN` = Redis/KV key pattern.

### 1. Enumerate every storage layer touched

> Before verifying any layer, list all of them. Skipping one is how #466 and #477 hid.

```bash
# SQL tables (SQLite)
python3 -c "
import sqlite3, sys
conn = sqlite3.connect('db/expediente.db')  # adjust path
tables = conn.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()
for t in tables: print(t[0])
"

# SQL tables (PostgreSQL)
psql "$DATABASE_URL" -c "\dt" 2>/dev/null
# Or from inside Docker
docker exec <container> psql -U postgres -d <db> -c '\dt'

# Qdrant collections
curl -s http://localhost:6333/collections | python3 -m json.tool | grep '"name"'

# MinIO / S3 buckets
# Inside compose network:
docker exec <minio-container> mc ls local/ 2>/dev/null
# Or via API:
curl -s http://localhost:9000/ | grep -o '<Name>[^<]*</Name>'

# Redis key namespaces (sample)
redis-cli --scan --pattern '*' | sed 's/:.*//' | sort -u | head -20

# Filesystem cache dirs
find . -type d -name 'cache' -o -name '.cache' | head -20
find . -type d -name 'ocr_*' -o -name 'fts_*' | head -20

# Qdrant payload namespaces (check what fields are stored)
curl -s "http://localhost:6333/collections/$COLLECTION/points/scroll" \
  -d '{"limit":1}' -H 'Content-Type: application/json' \
  | python3 -m json.tool | head -30
```

List every layer found. This is your checklist for checks 2-4. FAIL if you cannot enumerate (storage connection unavailable — note it and continue with static analysis).

### 2. Producer present for each layer

> For every layer enumerated in check 1: is there ≥1 write operation in production code pointing at it?

```bash
# SQL INSERT / upsert
grep -rn "INSERT INTO $TABLE\|execute.*INSERT INTO $TABLE\|upsert.*$TABLE\|conn\.execute.*$TABLE" \
  --include='*.py' --include='*.ts' --include='*.rs' --include='*.go' \
  src/ mcp_server/ | grep -v 'test\|spec\|migration\|schema'

# SQLite via ORM (SQLAlchemy, Tortoise, Prisma)
grep -rn "$TABLE\|$ModelClass" src/ --include='*.py' \
  | grep -iE '\.save\(\)|\.create\(|\.insert\(|session\.add\(' \
  | grep -v 'test\|spec'

# Qdrant upsert
grep -rn "upsert\|upload_points\|upload_collection" --include='*.py' src/ \
  | grep -i "$COLLECTION\|collection_name"

# MinIO / S3 put
grep -rn "put_object\|upload_file\|upload_fileobj" --include='*.py' src/ \
  | grep -v 'test'

# Redis set
grep -rn "\.set\(.*$KEY_PATTERN\|\.setex\(.*$KEY_PATTERN\|\.hset\(" --include='*.py' src/

# Filesystem write
grep -rn "open.*w\|write_bytes\|write_text\|shutil\.copy\|json\.dump" --include='*.py' src/ \
  | grep "$DIR\|$KEY_PATTERN"
```

PASS if ≥1 match per layer. FAIL if 0 matches — the table/collection/dir is an orphan (this was `#466` and `#477`). Note the exact layer name in the FAIL.

### 3. Producer reachable from main entry point

> A producer in dead code is the same as no producer.

Open `ENTRY_POINTS` (from `.claude/hooks/project.conf` or the project's main ingest script). Trace the call graph from entry point to the INSERT/upsert/write found in check 2. Paste the chain:

```
mcp_server/main.py
  → uvicorn app (routes registered)
    → POST /ingest → ingest_document() in services/ingest.py:88
      → ocr_pipeline.run() in services/ocr.py:34
        → cache_ocr_result() in services/ocr_cache.py:12
          → INSERT INTO ocr_cache (this is the producer)
```

If a function exists in the module but is never called from the entry point (not registered as a route, not called from a scheduler, not in a startup hook) — it is dead code. FAIL — the producer exists statically but never executes (this was the exact mechanism in `#477`: `AnnotationPipeline.run()` existed but was never called from `ingest_document()`).

```bash
# Quick reachability smoke-check: grep for the producer function name in the ingest pipeline
grep -rn "build_folio_index\|AnnotationPipeline\|cache_ocr_result" \
  mcp_server/services/ingest.py mcp_server/main.py mcp_server/routes/
```

PASS if the chain is traceable to the entry point with actual file:line refs. FAIL if any hop is missing.

### 4. Live check — count rows/files after fixture run

> After running a fixture ingest, measure the storage layer. Zero means the producer never fired.

```bash
# Run the fixture ingest (adapt to project)
python3 -m pytest tests/fixtures/ingest_single_doc.py -s 2>&1 | tail -5
# Or the real ingest CLI:
python3 -m mcp_server.cli ingest --file tests/fixtures/sample.pdf --case-id fixture-001

# SQLite row count
python3 -c "
import sqlite3
conn = sqlite3.connect('db/expediente.db')
for table in ['ocr_cache', 'fts_content', 'folio_mappings', 'case_entities']:
    count = conn.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]
    status = 'OK' if count > 0 else 'ZERO — producer never fired'
    print(f'{table}: {count} rows — {status}')
"

# PostgreSQL row count (from host)
docker exec <pg-container> psql -U postgres -d <db> -c \
  "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"

# Qdrant point count
curl -s http://localhost:6333/collections/$COLLECTION \
  | python3 -c "import sys,json; c=json.load(sys.stdin); print(c['result']['points_count'], 'points')"

# Filesystem cache: count files
find ./cache/$DIR -type f | wc -l
ls -la ./cache/$DIR/ | head -10

# Redis: count matching keys
redis-cli --scan --pattern "$KEY_PATTERN*" | wc -l

# MinIO: count objects in bucket
docker exec <minio-container> mc ls --recursive local/$BUCKET | wc -l
```

PASS if every layer has count > 0 after the fixture run. FAIL if any layer has 0 — that layer's producer is either unreachable (check 3 failed) or the producer wrote to a different key/path than the reader expects (split-brain). Print the exact count and layer name.

If you CANNOT run the fixture (no DB available, sandboxed env), say so explicitly: "Check 4 CANNOT RUN: requires running expediente-processor with MINIO credentials." Do not fabricate counts.

### 5. Migration consistency — if write path changed, all read sites updated

> When a PR changes where data is written (new table name, new key format, new directory), every existing reader must be updated in the same PR. Split-brain between writer and reader is what produced #456 and #476.

```bash
# Find all read sites for the OLD path/key/table
git log --oneline -20  # find the commit that changed the write path
git diff HEAD~1 -- '*.py' '*.ts' | grep '^[-+]' | grep -E "cache_ocr|folio_map|case_entit" | head -20

# For each changed write path, grep for the old name still in use as a read
OLD_KEY="cache_ocr_"
NEW_KEY="ocr_results/"
echo "=== Reads still using OLD path ==="
grep -rn "$OLD_KEY" src/ --include='*.py' | grep -iE 'get\|read\|load\|fetch\|open\|SELECT'

echo "=== Reads using NEW path ==="
grep -rn "$NEW_KEY" src/ --include='*.py' | grep -iE 'get\|read\|load\|fetch\|open\|SELECT'

# If OLD reads exist: split-brain. Both must be zero or both non-zero.
# If only OLD reads exist and only NEW writes exist: data is written and never read.
```

PASS if 0 old-path reads remain after the write path migration. FAIL if old-path reads still exist — the migration is half-done and readers will silently miss all new data (this was the exact structure of #456 and #476).

N/A if this PR did not change any write path.

## Verdict format

```
Storage verdict for expediente-processor ingest pipeline:

  Layers enumerated: ocr_cache (SQLite), fts_content (FTS5), folio_mappings (SQLite),
                     case_entities (SQLite), pages_qdrant (Qdrant), pdf_originals (MinIO)

  Layer: ocr_cache
    2. producer-present:     FAIL — 0 grep matches for INSERT INTO ocr_cache in src/ (not test/)
    3. producer-reachable:   SKIP (no producer found)
    4. live-count:           SKIP
    → ROOT CAUSE: cache_ocr_result() writes to filesystem ./cache/ocr/{hash}.json,
                  NOT to SQLite. Split-brain: write=filesystem, read=SQLite.

  Layer: folio_mappings
    2. producer-present:     PASS — build_folio_index() does INSERT INTO folio_mappings
    3. producer-reachable:   FAIL — build_folio_index() never called from ingest_document()
                                    grep returns 0 matches in routes/ and services/ingest.py
    4. live-count:           FAIL — 0 rows after fixture run (confirmed: producer unreachable)
    5. migration-check:      N/A

  Layer: pages_qdrant
    2. producer-present:     PASS — qdrant_client.upsert() in services/vector_store.py:88
    3. producer-reachable:   PASS — ingest_document → embed_pages → upsert (ingest.py:44→67→88)
    4. live-count:           PASS — 174 points after fixture run
    5. migration-check:      N/A

Verdict: NOT DONE. 2 layers broken: ocr_cache (split-brain) and folio_mappings (dead producer).
Action: fix ocr_cache write path to SQLite OR fix reader to look at filesystem; call
        build_folio_index() from ingest_document(). Re-run check 4 to confirm counts > 0.
Commit prefix: wip:
```

Or on full pass:

```
Storage verdict for expediente-processor ingest pipeline:

  Layers: ocr_cache, fts_content, folio_mappings, case_entities, pages_qdrant, pdf_originals

  All layers:
    2. producer-present:     PASS — INSERT / upsert / put found for each layer
    3. producer-reachable:   PASS — all producers traceable from ingest_document() entry point
    4. live-count:           PASS — ocr_cache: 1 row, fts_content: 174 rows, folio_mappings: 63,
                                    case_entities: 12, pages_qdrant: 174 points, pdf_originals: 1 obj
    5. migration-check:      N/A — no write paths changed in this PR

Verdict: STORAGE VERIFIED. All layers populated. Proceeding with feat: commit.
```

## Interaction with verify-done

`verify-done` check 6 (runtime trace) confirms the code path executed. It PASS if a log line appeared. `verify-storage` check 4 confirms that the execution actually wrote data — a handler can log "ocr complete" and write to the wrong path simultaneously. Run both when persistence is claimed.

## When NOT to use

- Pure in-memory computation with no I/O to any persistent store.
- A PR that only changes business logic, not the storage layer.
- Exploring or reading code.

If a PR touches `INSERT`, `upsert`, `put_object`, `write_bytes`, `redis.set`, or any schema migration — run this skill.

## Relation to CLAUDE.md Definition of Done

This skill enforces DoD check 2 (evidence of execution) specifically for storage: the log line showing "cached" or "indexed" is not sufficient evidence — you must also show `COUNT(*) > 0`. A persistent layer with zero rows has the same user-visible outcome as one that doesn't exist.

## References

- `guardrails/README.md` — layered defense overview
- `guardrails/docs/FAKE_WORK_AUDIT.md` — real case (GainShield, 60% fake-work despite 205 green tests)
- `guardrails/docs/DEFINITION_OF_DONE.md` — norm block for CLAUDE.md
- `bot202102/expediente-processor#456` — OCR cache split-brain (SQLite write, JSON read)
- `bot202102/expediente-processor#458` — FTS5 silent partial index (5/174 missing)
- `bot202102/expediente-processor#466` — folio_mappings 0 rows (producer unreachable)
- `bot202102/expediente-processor#476` — LLM page-meta cache split-brain (second instance of #456 pattern)
- `bot202102/expediente-processor#477` — case_entities 0 rows (AnnotationPipeline never invoked)
- `.claude/hooks/integration-gate.sh` — mechanical Stop gate (complementary layer)
