#!/usr/bin/env bash
# test_intra_file_caller.sh — symbols used only within their own definer file
# (FastAPI Depends pattern, Pydantic field types, decorator factories) must
# NOT be flagged as ghosts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/app"

cat > "$WORK/main.py" <<'EOF'
from app.routes import router
EOF

cat > "$WORK/app/__init__.py" <<'EOF'
EOF

cat > "$WORK/app/routes.py" <<'EOF'
"""verify_auth defined and used in same file via Depends — must NOT flag."""
from fastapi import APIRouter, Depends

router = APIRouter()

def verify_auth(token: str = "x"):
    return token

@router.get("/me")
def me(auth=Depends(verify_auth)):
    return {"auth": auth}

def real_ghost():
    """No reference anywhere — MUST flag."""
    return 0
EOF

cd "$WORK"
export ENTRY_POINTS="main.py"
export SRC_GLOBS="app"

OUTPUT=$(bash "$CHECKER")

echo "Checker output:"
echo "$OUTPUT"
echo ""

if echo "$OUTPUT" | grep -qw "verify_auth"; then
    echo "FAIL: verify_auth flagged despite intra-file caller via Depends()" >&2
    exit 1
fi
if ! echo "$OUTPUT" | grep -qw "real_ghost"; then
    echo "FAIL: real_ghost not flagged" >&2
    exit 1
fi

echo "PASS: intra-file caller pattern handled, real ghost still detected"
