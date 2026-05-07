#!/usr/bin/env bash
# test_ghost_in_python_blocks.sh — adding a NEW ghost on the Python side
# (after the multi-lang baseline is captured) must trigger integration-gate
# exit 2 with a message that contains 'python:' and the new symbol name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/python/myapp" "$WORK/rust/crates/mycrate/src"
cat > "$WORK/python/myapp/cli.py" <<'EOF'
from myapp.wired import wired_py
if __name__ == "__main__":
    wired_py()
EOF
touch "$WORK/python/myapp/__init__.py"
cat > "$WORK/python/myapp/wired.py" <<'EOF'
def wired_py():
    return 1
EOF
cat > "$WORK/python/myapp/ghost.py" <<'EOF'
def python_existing_ghost():
    return 99
EOF

cat > "$WORK/rust/crates/mycrate/src/main.rs" <<'EOF'
fn main() {
    println!("hello");
}
EOF
cat > "$WORK/rust/crates/mycrate/src/lib.rs" <<'EOF'
pub fn rust_existing_ghost() -> i32 {
    99
}
EOF
cat > "$WORK/rust/crates/mycrate/Cargo.toml" <<'EOF'
[package]
name = "mycrate"
version = "0.1.0"
edition = "2021"
EOF

cd "$WORK"
mkdir -p .claude/hooks/lang
cp "$GUARDRAILS_ROOT/.claude/hooks/integration-gate.sh" .claude/hooks/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/python.sh"      .claude/hooks/lang/
cp "$GUARDRAILS_ROOT/.claude/hooks/lang/rust.sh"        .claude/hooks/lang/
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

cat > .claude/hooks/project.conf <<EOF
LANGS="python rust"
ENTRY_POINTS_python="python/myapp/cli.py"
ENTRY_POINTS_rust="rust/crates/mycrate/src/main.rs"
SRC_GLOBS_python="python"
SRC_GLOBS_rust="rust/crates"
EOF

# Run 1: capture baseline.
bash .claude/hooks/integration-gate.sh > /dev/null 2>&1 || true

# Add a NEW python ghost.
cat > "$WORK/python/myapp/new_ghost.py" <<'EOF'
def python_NEW_ghost():
    return 7
EOF

# Run 2: must exit 2 and mention python:.
set +e
OUTPUT=$(bash .claude/hooks/integration-gate.sh 2>&1)
RC=$?
set -e

if [ $RC -ne 2 ]; then
    echo "FAIL: expected exit 2 (block), got $RC" >&2
    echo "Output:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "python_NEW_ghost"; then
    echo "FAIL: gate output missing the new ghost name 'python_NEW_ghost'" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "python:"; then
    echo "FAIL: gate output missing 'python:' lang prefix in the new ghost line" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

echo "PASS: new python ghost blocks gate (exit 2) with python: prefix in message"
