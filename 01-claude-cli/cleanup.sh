#!/usr/bin/env bash
set -x

cf delete agent-cli -f
cf delete-service anthropic-creds -f
cf delete-service github-creds -f
