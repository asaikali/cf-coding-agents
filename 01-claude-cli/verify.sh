#!/usr/bin/env bash
set -eu

APP=agent-cli

cf run-task "$APP" --name versions --command './versions.sh'

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
