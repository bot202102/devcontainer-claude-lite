#!/bin/bash
# Setup git hooks for quality gates on commit (Python)
# Run once in your project root: bash .devcontainer/setup-hooks.sh
#
# Modes:
#   bash .devcontainer/setup-hooks.sh        # ruff only (fast, default)
#   bash .devcontainer/setup-hooks.sh full    # ruff + file checks + bandit

set -e

MODE="${1:-minimal}"

echo "Installing Python quality tools..."
pip install ruff pre-commit

if [ "$MODE" = "full" ]; then
  echo "Creating full pre-commit config (ruff + file checks + bandit)..."
  pip install bandit
  cat > .pre-commit-config.yaml << 'YAML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
        exclude: \.md$
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-toml
      - id: check-added-large-files
        args: [--maxkb=5000]
      - id: check-merge-conflict
      - id: detect-private-key

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.4
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format

  - repo: https://github.com/PyCQA/bandit
    rev: 1.8.3
    hooks:
      - id: bandit
        args: [-c, pyproject.toml]
        additional_dependencies: ['bandit[toml]']
        exclude: ^tests/
YAML
else
  echo "Creating minimal pre-commit config (ruff only)..."
  cat > .pre-commit-config.yaml << 'YAML'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.4
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
YAML
fi

echo "Installing pre-commit hooks..."
pre-commit install

echo ""
echo "Done. On each commit, quality gates run on staged files only."
echo "Zero background processes, zero wasted CPU."
echo ""
echo "To test: git add a .py file and run 'git commit'"
