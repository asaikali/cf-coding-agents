#!/usr/bin/env bash
set -eu

APP=agent-issue

# --process task tells cf run-task to inherit memory, disk, and the default
# command from the task process declared in the manifest. We override just
# the command here so the task runs versions.sh instead of agent.py.
cf run-task "$APP" \
  --name versions \
  --process task \
  --command 'bash versions.sh'

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
