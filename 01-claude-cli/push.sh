#!/usr/bin/env bash
set -euo pipefail

# Secrets live in the 'coding-agent-secrets' user-provided service, bound in
# the manifest. Run ./create-services.sh first to create or rotate it.
cf push agent --task
