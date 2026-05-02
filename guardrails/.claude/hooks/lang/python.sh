#!/usr/bin/env bash
# python.sh — public top-level symbols without a caller in production code.
#
# Outputs `file:line:symbol` for every public top-level def/class whose name
# is not referenced anywhere in the consumer corpus (entry-point files +
# all .py under SRC_GLOBS, minus tests/cache/etc.).
#
# Improvements over upstream (devcontainer-claude-lite/guardrails):
#   1. Single-pass identifier scan via Python (was O(N²): nested grep + find . -name '*.py'
#      per symbol, which hangs when an entry-point lives at the project root because
#      `dirname` resolves to "." and the inner find walks the whole workspace).
#   2. Wider exclude list: __pycache__, archive/, cache/, data/, output/, logs/, results/,
#      test_output_*/, output_*/ — these may contain stale .py files that confuse the heuristic.
#   3. Honors CONSUMER_GLOBS env var (defaults to SRC_GLOBS): lets you scan a wider
#      consumer corpus than where definers live (e.g. include scripts/ as callers).
#   4. Cross-file caller heuristic: a symbol is "used" if it appears as an identifier
#      in ANY consumer file other than its own definer file. Same-file-only references
#      (def foo(): foo()) still count via SKIP_SELF=0 (default 1 to match upstream intent).
#   5. Loud failure on missing python3.
#
# Env (project.conf):
#   ENTRY_POINTS    REQUIRED. Space-separated entry-point files.
#   SRC_GLOBS       Optional. Space-separated dirs holding production source.
#                   Default: src/ if present, else lib/ if present, else fail loud.
#   CONSUMER_GLOBS  Optional. Defaults to SRC_GLOBS.
#   TEST_EXCLUDES   Optional. Extra grep -v patterns applied to file list.
#   SKIP_SELF       Optional 0|1. 1 = same-file references don't count as caller (default 1).
#   GHOST_SKIP_NAMES Optional. Extra symbol names to skip (space-separated).

set -u

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "python.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python.sh: required tool 'python3' not found in PATH" >&2
    exit 1
fi

SRC_GLOBS="${SRC_GLOBS:-}"
CONSUMER_GLOBS="${CONSUMER_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"
SKIP_SELF="${SKIP_SELF:-1}"
GHOST_SKIP_NAMES="${GHOST_SKIP_NAMES:-}"

# Default SRC_GLOBS: prefer src/ or lib/ only if they actually contain .py files.
if [ -z "$SRC_GLOBS" ]; then
    if [ -d src ] && find src -maxdepth 4 -name '*.py' -type f 2>/dev/null | grep -q .; then
        SRC_GLOBS="src"
    elif [ -d lib ] && find lib -maxdepth 4 -name '*.py' -type f 2>/dev/null | grep -q .; then
        SRC_GLOBS="lib"
    else
        echo "python.sh: no SRC_GLOBS set and no src/ or lib/ with .py files found." >&2
        echo "  Set SRC_GLOBS in .claude/hooks/project.conf to your package directory." >&2
        exit 1
    fi
fi
[ -z "$CONSUMER_GLOBS" ] && CONSUMER_GLOBS="$SRC_GLOBS"

export ENTRY_POINTS SRC_GLOBS CONSUMER_GLOBS TEST_EXCLUDES SKIP_SELF GHOST_SKIP_NAMES

python3 <<'PYEOF'
import ast
import os
import re
import sys
from pathlib import Path

ENTRY_POINTS    = (os.environ.get("ENTRY_POINTS")    or "").split()
SRC_GLOBS       = (os.environ.get("SRC_GLOBS")       or "").split()
CONSUMER_GLOBS  = (os.environ.get("CONSUMER_GLOBS")  or "").split()
TEST_EXCLUDES   = (os.environ.get("TEST_EXCLUDES")   or "").split()
SKIP_SELF       = (os.environ.get("SKIP_SELF") or "1") == "1"
EXTRA_SKIP      = set((os.environ.get("GHOST_SKIP_NAMES") or "").split())

EXCLUDE_RE = re.compile(
    r"(/test_|_test\.py$|/tests/|/__pycache__/|/venv/|/\.venv/|/node_modules/"
    r"|/\.tox/|/build/|/dist/|/\.git/|/cache/|/cache_utils/|/archive/|/output/"
    r"|/output_results/|/test_output_[^/]*/|/logs/|/data/|\.egg-info/)"
)

# Default symbols that should never be flagged — they are framework hooks
# or ubiquitous infrastructure entry-points.
SKIP_NAMES = {
    "main", "Config", "Error", "Result", "create_app", "app", "router",
    "handler", "setup", "teardown", "Meta",
} | EXTRA_SKIP


def collect_py_files(roots):
    """Return sorted list of .py files under each root, applying excludes."""
    out = set()
    for r in roots:
        p = Path(r)
        if p.is_file() and p.suffix == ".py":
            if not EXCLUDE_RE.search("/" + str(p)):
                out.add(str(p))
            continue
        if not p.is_dir():
            continue
        for f in p.rglob("*.py"):
            s = str(f)
            if EXCLUDE_RE.search("/" + s):
                continue
            if any(pat and pat in s for pat in TEST_EXCLUDES):
                continue
            out.add(s)
    return sorted(out)


definer_files  = collect_py_files(SRC_GLOBS)
consumer_files = sorted(set(collect_py_files(CONSUMER_GLOBS)) | set(ENTRY_POINTS))

if not definer_files:
    sys.exit(0)

# Decorator names that mean "the framework calls this for me, no explicit caller exists":
#   @app.get / @router.post / @app.route / @router.websocket / @router.api_route / etc.
#   @celery.task, @shared_task, @click.command, @pytest.fixture (rare in src), @app.cli.command
#   @lru_cache / @cache (caching wrappers — the wrapped fn is reached via the wrapper)
FRAMEWORK_DECORATOR_ATTRS = {
    "get", "post", "put", "patch", "delete", "options", "head", "websocket",
    "api_route", "route", "task", "command", "fixture", "step", "tool",
    "on_event", "exception_handler", "middleware", "include_router",
}
FRAMEWORK_DECORATOR_NAMES = {
    "shared_task", "task", "lru_cache", "cache", "cached", "tool",
    "register", "callback", "hookimpl", "subscribe",
}

def has_framework_decorator(node):
    for d in getattr(node, "decorator_list", []):
        # @something(...) — unwrap Call
        target = d.func if isinstance(d, ast.Call) else d
        if isinstance(target, ast.Attribute) and target.attr in FRAMEWORK_DECORATOR_ATTRS:
            return True
        if isinstance(target, ast.Name) and target.id in FRAMEWORK_DECORATOR_NAMES:
            return True
    return False

# 1. Extract public top-level def/class symbols.
defs = []  # (file, line, symbol)
for fp in definer_files:
    try:
        src = Path(fp).read_text(encoding="utf-8", errors="ignore")
        tree = ast.parse(src, fp)
    except (OSError, SyntaxError, ValueError):
        continue
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            name = node.name
            if name.startswith("_") or name in SKIP_NAMES:
                continue
            if has_framework_decorator(node):
                continue
            defs.append((fp, node.lineno, name))

if not defs:
    sys.exit(0)

# 2. Build per-file identifier index (one pass over the consumer corpus).
#    For OTHER files we only need set membership.
#    For the SAME file as the definer we need a count, so we can distinguish
#    "name appears once = just the def line" from "name appears N≥2 = intra-file caller"
#    (FastAPI Depends(verify_auth), Pydantic field types, decorator factories…).
IDENT_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
file_idents = {}    # fp -> set(names)
file_counts = {}    # fp -> {name: count}
for fp in consumer_files:
    try:
        text = Path(fp).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        file_idents[fp] = set()
        file_counts[fp] = {}
        continue
    tokens = IDENT_RE.findall(text)
    file_idents[fp] = set(tokens)
    counts = {}
    for t in tokens:
        counts[t] = counts.get(t, 0) + 1
    file_counts[fp] = counts

# 3. For each public def, "used" if:
#      (a) name appears in ANY consumer file other than its definer, OR
#      (b) name appears ≥2× in its definer file (def line + intra-file caller).
for fp, line, name in defs:
    used = False
    for cf, idents in file_idents.items():
        if cf == fp:
            continue
        if name in idents:
            used = True
            break
    if not used and not SKIP_SELF:
        if file_counts.get(fp, {}).get(name, 0) >= 2:
            used = True
    if not used and SKIP_SELF:
        # Intra-file caller still counts: the definition is one occurrence,
        # any additional occurrence is a real reference.
        if file_counts.get(fp, {}).get(name, 0) >= 2:
            used = True
    if not used:
        print(f"{fp}:{line}:{name}")
PYEOF
