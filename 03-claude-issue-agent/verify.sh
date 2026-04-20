#!/usr/bin/env bash
set -eu

APP=agent-issue

cf run-task "$APP" \
  --name versions \
  --command 'bash versions.sh' \
  -m 2G -k 8G

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
