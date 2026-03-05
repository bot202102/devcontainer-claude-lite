#!/bin/bash
# Setup git hooks for quality gates on commit
# Run this once in your project root: bash .devcontainer/setup-hooks.sh
#
# Auto-detects npm vs pnpm. Supports monorepos.

set -e

# Detect package manager
if [ -f "pnpm-lock.yaml" ] || [ -f "pnpm-workspace.yaml" ]; then
  PM="pnpm"
  PMX="pnpm exec"
elif [ -f "bun.lockb" ]; then
  PM="bun"
  PMX="bunx"
else
  PM="npm"
  PMX="npx"
fi

echo "Detected: $PM"
echo "Installing husky + lint-staged..."
$PM install -D husky lint-staged eslint prettier

echo "Initializing husky..."
$PMX husky init

echo "Configuring pre-commit hook..."
echo "$PMX lint-staged" > .husky/pre-commit

# Add lint-staged config to package.json (if not already present)
node -e "
const pkg = require('./package.json');
if (pkg['lint-staged']) {
  console.log('lint-staged config already exists, skipping.');
  process.exit(0);
}
pkg['lint-staged'] = {
  '*.{ts,tsx,js,jsx}': ['eslint --fix', 'prettier --write'],
  '*.{json,md,css,scss}': ['prettier --write']
};
require('fs').writeFileSync('./package.json', JSON.stringify(pkg, null, 2) + '\n');
console.log('Added lint-staged config to package.json.');
"

echo ""
echo "Done. On each commit, lint-staged will run ESLint + Prettier"
echo "only on staged files. No background processes, no wasted CPU."
echo ""
echo "To test: git add a file and run 'git commit'"
