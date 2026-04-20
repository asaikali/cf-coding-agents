#!/usr/bin/env bash
set -euo pipefail

# Secrets live in the 'anthropic-creds' and 'github-creds' user-provided
# services, bound in the manifest. Run ./create-services.sh first.
cf push agent-sdk --task
