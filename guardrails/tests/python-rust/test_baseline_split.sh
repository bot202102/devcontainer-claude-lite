#!/usr/bin/env bash
# test_baseline_split.sh — multi-lang install must produce a baseline with
# both 'python:' and 'rust:' prefixed entries when both sides have ghosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture: python/ + rust/ siblings with one ghost each.
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
def python_ghost_func():
    return 99
EOF

cat > "$WORK/rust/crates/mycrate/Cargo.toml" <<'EOF'
[package]
name = "mycrate"
version = "0.1.0"
edition = "2021"
EOF
cat > "$WORK/rust/crates/mycrate/src/main.rs" <<'EOF'
fn main() {
    println!("hello");
}
EOF
cat > "$WORK/rust/crates/mycrate/src/lib.rs" <<'EOF'
pub fn rust_ghost_func() -> i32 {
    99
}
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

# First run: creates multi-lang baseline. exit 0.
set +e
bash .claude/hooks/integration-gate.sh
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: first run exit code $RC (expected 0)" >&2
    exit 1
fi

# Assert baseline contains both prefixes.
if ! grep -qE '^python:' .claude/ghost-baseline.txt; then
    echo "FAIL: baseline missing 'python:' prefix entries" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi
if ! grep -qE '^rust:' .claude/ghost-baseline.txt; then
    echo "FAIL: baseline missing 'rust:' prefix entries" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi
if ! grep -q "python_ghost_func" .claude/ghost-baseline.txt; then
    echo "FAIL: python ghost not captured" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi
if ! grep -q "rust_ghost_func" .claude/ghost-baseline.txt; then
    echo "FAIL: rust ghost not captured" >&2
    cat .claude/ghost-baseline.txt >&2
    exit 1
fi

echo "PASS: multi-lang baseline has both python: and rust: prefixed entries"
