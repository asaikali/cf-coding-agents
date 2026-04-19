#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://downloads.claude.ai/claude-code-releases"
PLATFORM="linux-x64"
OUTPUT_DIR="./bin"
OUTPUT_FILE="${OUTPUT_DIR}/claude"

mkdir -p "${OUTPUT_DIR}"

VERSION="$(curl -fsSL "${BASE_URL}/latest")"
URL="${BASE_URL}/${VERSION}/${PLATFORM}/claude"

echo "Downloading Claude Code ${VERSION} (${PLATFORM})..."
curl -fsSL -o "${OUTPUT_FILE}" "${URL}"
chmod +x "${OUTPUT_FILE}"

echo "Downloaded to: ${OUTPUT_FILE}"