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

# --- Apache Maven --------------------------------------------------------
MAVEN_VERSION="3.9.15"
MAVEN_TGZ="$(mktemp)"
echo "Downloading Apache Maven ${MAVEN_VERSION}..."
curl -fsSL -o "${MAVEN_TGZ}" \
  "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
rm -rf "${OUTPUT_DIR}/maven"
tar -xzf "${MAVEN_TGZ}" -C "${OUTPUT_DIR}"
mv "${OUTPUT_DIR}/apache-maven-${MAVEN_VERSION}" "${OUTPUT_DIR}/maven"
rm -f "${MAVEN_TGZ}"
echo "Installed Maven to: ${OUTPUT_DIR}/maven"
