#!/usr/bin/env bash
set -eu

APP=agent-sdk

cf run-task "$APP" --name versions --command 'bash versions.sh'

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
