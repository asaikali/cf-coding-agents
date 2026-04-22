#!/usr/bin/env bash
# Usage: ./create-services.sh          # create (first time)
#        ./create-services.sh update   # rotate values on an existing service
#
# Same UPS contract as the other scenarios. If you already created the
# services for scenarios 1–3 in this CF space, skip this — the manifest
# just binds them by name.
set -e

case "${1:-create}" in
  create) cmd=cups ;;
  update) cmd=uups ;;
  *) echo "usage: $0 [create|update]"; exit 1 ;;
esac

GITHUB_TOKEN=$(gh auth token)

cf $cmd anthropic-creds -p <(printf '{"api_key":"%s"}' "$ANTHROPIC_API_KEY")
cf $cmd github-creds    -p <(printf '{"token":"%s"}'   "$GITHUB_TOKEN")
