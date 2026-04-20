#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="./bin"
mkdir -p "${OUTPUT_DIR}"

# --- Claude Code ---------------------------------------------------------
CLAUDE_BASE="https://downloads.claude.ai/claude-code-releases"
CLAUDE_PLATFORM="linux-x64"
CLAUDE_OUT="${OUTPUT_DIR}/claude"
CLAUDE_VERSION="$(curl -fsSL "${CLAUDE_BASE}/latest")"
echo "Downloading Claude Code ${CLAUDE_VERSION} (${CLAUDE_PLATFORM})..."
curl -fsSL -o "${CLAUDE_OUT}" "${CLAUDE_BASE}/${CLAUDE_VERSION}/${CLAUDE_PLATFORM}/claude"
chmod +x "${CLAUDE_OUT}"
echo "Downloaded to: ${CLAUDE_OUT}"
