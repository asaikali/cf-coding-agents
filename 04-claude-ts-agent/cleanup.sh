#!/usr/bin/env bash
set -x

cf delete agent-ts -f
cf delete-service anthropic-creds -f
cf delete-service github-creds -f
