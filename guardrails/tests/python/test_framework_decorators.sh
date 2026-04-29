#!/usr/bin/env bash
# test_framework_decorators.sh — assert FastAPI/Celery/Click handlers
# are NOT flagged as ghosts even though no Python code calls them by name.
#
# Pre-fix: `def list_users(): ...` decorated with `@router.get("/users")` had
# no `list_users` token elsewhere in the corpus, so it was flagged as a ghost.
# This polluted baselines with false positives in any FastAPI/Flask/Celery project.
#
# Post-fix: AST-walks decorators; @<obj>.{get,post,...,task,command,...} or
# @<name in {shared_task,lru_cache,cache,...}> means "framework-invoked, exempt".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/api"

cat > "$WORK/main.py" <<'EOF'
"""Entry-point that mounts the FastAPI router."""
from fastapi import FastAPI
from api.routes import router

app = FastAPI()
app.include_router(router)
EOF

cat > "$WORK/api/__init__.py" <<'EOF'
EOF

cat > "$WORK/api/routes.py" <<'EOF'
"""Mix of framework-decorated handlers (exempt) and a real ghost."""
from fastapi import APIRouter
from celery import shared_task
from functools import lru_cache

router = APIRouter()

@router.get("/users")
def list_users():
    """FastAPI handler — framework calls this, no code references list_users."""
    return []

@router.post("/users")
async def create_user(name: str):
    """Async FastAPI handler — same exemption."""
    return {"name": name}

@shared_task
def background_job(payload):
    """Celery task — invoked by name from the worker, not from python code."""
    return payload

@lru_cache(maxsize=128)
def expensive_calc(x: int) -> int:
    """Cached helper — wrapper changes the call mechanism."""
    return x * x

def truly_orphan_helper():
    """No decorator, no caller — MUST be flagged."""
    return None
EOF

cd "$WORK"
export ENTRY_POINTS="main.py"
export SRC_GLOBS="api"

OUTPUT=$(bash "$CHECKER")

echo "Checker output:"
echo "$OUTPUT"
echo ""

# Assertion 1: every framework-decorated symbol must NOT be flagged.
for sym in list_users create_user background_job expensive_calc; do
    if echo "$OUTPUT" | grep -qw "$sym"; then
        echo "FAIL: $sym flagged as ghost despite framework decorator" >&2
        exit 1
    fi
done

# Assertion 2: the truly orphan helper MUST be flagged.
if ! echo "$OUTPUT" | grep -qw "truly_orphan_helper"; then
    echo "FAIL: truly_orphan_helper not flagged (false negative)" >&2
    exit 1
fi

echo "PASS: framework-decorated symbols exempt; real orphan flagged"
