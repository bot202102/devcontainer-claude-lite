#!/usr/bin/env bash
# test_postool_picks_correct_checker.sh — new-symbol-guard.sh under LANGS
# must dispatch by file extension. Editing a .py file uses Python rules
# (warn on def/class without _ prefix); editing a .rs file uses Rust rules
# (warn on pub fn/struct/enum/trait without caller).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/python" "$WORK/rust/src" "$WORK/.claude/hooks/lang"
cp "$GUARDRAILS_ROOT/.claude/hooks/new-symbol-guard.sh" "$WORK/.claude/hooks/"
chmod +x "$WORK/.claude/hooks/new-symbol-guard.sh"

cat > "$WORK/python/orphan.py" <<'EOF'
def py_orphan():
    return 1
EOF
cat > "$WORK/rust/src/orphan.rs" <<'EOF'
pub fn rust_orphan() -> i32 {
    1
}
EOF
cat > "$WORK/python/main.py" <<'EOF'
print("hi")
EOF
cat > "$WORK/rust/src/main.rs" <<'EOF'
fn main() {}
EOF

cd "$WORK"
cat > .claude/hooks/project.conf <<EOF
LANGS="python rust"
ENTRY_POINTS_python="python/main.py"
ENTRY_POINTS_rust="rust/src/main.rs"
EOF

# Edit .py → expect warning mentioning 'py_orphan'.
PY_OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$WORK"'/python/orphan.py"}}' \
    | bash .claude/hooks/new-symbol-guard.sh 2>&1)
if ! echo "$PY_OUT" | grep -q "py_orphan"; then
    echo "FAIL: editing .py did not warn on py_orphan" >&2
    echo "$PY_OUT" >&2
    exit 1
fi

# Edit .rs → expect warning mentioning 'rust_orphan'.
RS_OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$WORK"'/rust/src/orphan.rs"}}' \
    | bash .claude/hooks/new-symbol-guard.sh 2>&1)
if ! echo "$RS_OUT" | grep -q "rust_orphan"; then
    echo "FAIL: editing .rs did not warn on rust_orphan" >&2
    echo "$RS_OUT" >&2
    exit 1
fi

# Edit .ts (not in LANGS) → silent pass (no warning).
TS_FILE="$WORK/python/something.ts"
echo "export const foo = 1" > "$TS_FILE"
TS_OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$TS_FILE"'"}}' \
    | bash .claude/hooks/new-symbol-guard.sh 2>&1)
if [ -n "$TS_OUT" ]; then
    echo "FAIL: editing .ts (not in LANGS) produced output: $TS_OUT" >&2
    exit 1
fi

echo "PASS: postool dispatches by file extension under LANGS"
