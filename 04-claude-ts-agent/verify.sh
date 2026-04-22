#!/usr/bin/env bash
set -eu

APP=agent-ts

# End-to-end smoke test. Inherits 2G/8G from the task process declared in
# manifest.yaml via --process task.
cf run-task "$APP" \
  --name smoke \
  --process task \
  --command 'node_modules/.bin/tsx smoke_test.ts'

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
