#!/usr/bin/env bash
set -x

cf delete agent-issue -f
cf delete-service anthropic-creds -f
cf delete-service github-creds -f
