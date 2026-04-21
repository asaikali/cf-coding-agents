#!/usr/bin/env bash
set -eu

APP=agent-sdk

# End-to-end SDK smoke: the agent answers a trivial prompt via the Claude
# Agent SDK's query(). Proves the whole chain — python_buildpack, the
# bundled claude binary, .profile.d/vcap.sh's ANTHROPIC_API_KEY export,
# and the SDK's subprocess handshake. --process task inherits memory and
# disk from the task process declared in manifest.yaml.
cf run-task "$APP" \
  --name hello \
  --process task \
  --command 'uv run python agent.py "say hello in one short sentence"'

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent"
echo
echo "Quick tool probe (no API tokens, no agent invocation):"
echo "  cf run-task $APP --process task --command 'bash versions.sh'"
