#!/usr/bin/env bash
set -euo pipefail

# Ensure pyenv is available
if ! command -v pyenv &>/dev/null; then
    echo "Installing pyenv via Homebrew..."
    brew install pyenv
fi

# Install Python 3.11 if not present
if ! pyenv versions --bare | grep -q "^3\.11"; then
    pyenv install 3.11
fi

# Create virtual environment
PYTHON=$(pyenv prefix 3.11)/bin/python3
$PYTHON -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "Setup complete. Activate with: source .venv/bin/activate"
