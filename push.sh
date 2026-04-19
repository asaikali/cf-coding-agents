#!/usr/bin/env bash
set -euo pipefail

# Pull the GitHub token from gh's secure local storage (macOS Keychain via gh)
# so we don't have to keep it in a dotfile. Requires `gh auth login` first.
GH_TOKEN_VALUE="$(gh auth token)"

set -x
cf push agent --task \
  --var anthropic_api_key="$ANTHROPIC_API_KEY" \
  --var github_token="$GH_TOKEN_VALUE"
