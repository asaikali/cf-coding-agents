#!/usr/bin/env bash
set -eu

APP=agent-issue

# End-to-end smoke test: the agent clones TARGET_REPO, compiles it, boots
# the app, curls localhost, and shuts it down. Proves the whole chain —
# git HTTPS auth, JDK, Maven wrapper, Spring Boot startup, local HTTP,
# plus the SDK wiring itself. Takes 2-5 minutes and consumes Anthropic
# tokens each run.
#
# --process task inherits memory/disk from the task process declared in
# manifest.yaml.
cf run-task "$APP" \
  --name smoke \
  --process task \
  --command 'uv run python smoke_test.py'

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
echo
echo "Quick tool probe (does NOT invoke the agent, no API tokens used):"
echo "  cf run-task $APP --process task --command 'bash versions.sh'"
