#!/usr/bin/env bash
set -x

cf delete agent-py -f
cf delete-service anthropic-creds -f
cf delete-service github-creds -f
