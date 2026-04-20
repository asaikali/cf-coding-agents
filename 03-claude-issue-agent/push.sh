#!/usr/bin/env bash
set -euo pipefail

# Secrets live in the 'anthropic-creds' and 'github-creds' user-provided
# services, bound in the manifest. Run ./create-services.sh first if you
# haven't in this space yet.
cf push agent-issue --task
