#!/usr/bin/env bash
# Usage: ./create-services.sh          # create (first time)
#        ./create-services.sh update   # rotate values on an existing service
set -e

case "${1:-create}" in
  create) cmd=cups ;;
  update) cmd=uups ;;
  *) echo "usage: $0 [create|update]"; exit 1 ;;
esac

GITHUB_TOKEN=$(gh auth token)

cf $cmd anthropic-creds -p <(printf '{"api_key":"%s"}' "$ANTHROPIC_API_KEY")
cf $cmd github-creds    -p <(printf '{"token":"%s"}'   "$GITHUB_TOKEN")
