#!/bin/bash
# Setup git hooks for quality gates on commit
# Run this once in your project root: bash .devcontainer/setup-hooks.sh

set -e

echo "Installing husky + lint-staged..."
npm install -D husky lint-staged eslint prettier

echo "Initializing husky..."
npx husky init

echo "Configuring pre-commit hook..."
echo "npx lint-staged" > .husky/pre-commit

# Add lint-staged config to package.json
node -e "
const pkg = require('./package.json');
pkg['lint-staged'] = {
  '*.{ts,tsx,js,jsx}': ['eslint --fix', 'prettier --write'],
  '*.{json,md,css,scss}': ['prettier --write']
};
require('fs').writeFileSync('./package.json', JSON.stringify(pkg, null, 2) + '\n');
"

echo ""
echo "Done. On each commit, lint-staged will run ESLint + Prettier"
echo "only on staged files. No background processes, no wasted CPU."
echo ""
echo "To test: git add a file and run 'git commit'"
