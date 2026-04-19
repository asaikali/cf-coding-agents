#!/usr/bin/env bash
set -eu

APP=agent

cf run-task "$APP" --name gitcheck    --command 'git --version'
cf run-task "$APP" --name javacheck   --command 'java -version'
cf run-task "$APP" --name nodecheck   --command 'node --version && npm --version'
cf run-task "$APP" --name claudecheck --command './bin/claude --version < /dev/null'

echo
echo "Tasks submitted. Check status:  cf tasks $APP"
echo "View output:                    cf logs $APP --recent"
