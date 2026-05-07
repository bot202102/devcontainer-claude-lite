#!/bin/bash
# Sets up pre-commit hooks for Python + Rust.
# Runs ruff (Python) + clippy/rustfmt (Rust) ONLY on staged files at commit time.
# No background processes. Run once per project after first opening the devcontainer.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "→ Installing pre-commit (Python tool, system-wide)..."
sudo uv pip install --system pre-commit

echo "→ Writing .pre-commit-config.yaml..."

cat > .pre-commit-config.yaml <<'YAML'
# Pre-commit hooks for Python + Rust hybrid project.
# Runs only on staged files. No background processes.
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.7.4
    hooks:
      - id: ruff
        args: [--fix]
        files: ^python/.*\.py$
      - id: ruff-format
        files: ^python/.*\.py$

  - repo: local
    hooks:
      - id: cargo-fmt
        name: cargo fmt (rust/)
        entry: bash -c 'cd rust && cargo fmt -- --check'
        language: system
        files: ^rust/.*\.rs$
        pass_filenames: false
      - id: cargo-clippy
        name: cargo clippy (rust/)
        entry: bash -c 'cd rust && cargo clippy --all-targets -- -D warnings'
        language: system
        files: ^rust/.*\.(rs|toml)$
        pass_filenames: false
YAML

echo "→ Installing git hooks via pre-commit..."
pre-commit install

echo "✓ Setup complete. Pre-commit hooks active. They run on 'git commit'."
echo ""
echo "  Python checks: ruff (lint + format) on python/**/*.py"
echo "  Rust checks:   cargo fmt + clippy on rust/**/*.rs (when staged)"
