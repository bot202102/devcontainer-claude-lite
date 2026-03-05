#!/bin/bash
# Setup git hooks for quality gates on commit (Python)
# Run this once in your project root: bash .devcontainer/setup-hooks.sh

set -e

echo "Installing Python quality tools..."
pip install ruff pre-commit

echo "Creating pre-commit config..."
cat > .pre-commit-config.yaml << 'YAML'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.9.1
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
YAML

echo "Installing pre-commit hooks..."
pre-commit install

echo ""
echo "Done. On each commit, ruff will lint and format staged Python files."
echo "No background processes, no wasted CPU."
echo ""
echo "To test: git add a .py file and run 'git commit'"
