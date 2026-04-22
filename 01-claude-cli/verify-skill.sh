#!/usr/bin/env bash
set -eu

# End-to-end test of the github-issue-workflow skill against a real
# issue. The Claude Code CLI discovers .claude/skills/*/SKILL.md from
# cwd automatically — no SDK code, no settingSources option, nothing
# to configure inside the binary invocation. Proves that scenarios
# built on the CLI binary can be as capable as SDK-driven ones by
# putting the workflow in a skill file.
#
# Usage: ./verify-skill.sh <owner/repo> <issue-number>
# Example: ./verify-skill.sh asaikali/spring-petclinic 1

APP=agent-cli

if [ $# -lt 2 ]; then
  echo "usage: $0 <owner/repo> <issue-number>" >&2
  exit 1
fi

REPO="$1"
ISSUE="$2"

PROMPT="Use the github-issue-workflow skill to work on issue ${ISSUE} in repo ${REPO}."

# --dangerously-skip-permissions lets the CLI run Edit/Write/Bash without
# a TTY prompt (CF tasks have no interactive stdin). --process task
# inherits the 2G/8G resources configured on the task process so the
# Java build has room.
cf run-task "$APP" \
  --name "issue-${ISSUE}" \
  --process task \
  --command "./bin/claude -p '${PROMPT}' --dangerously-skip-permissions"

echo
echo "Check status:  cf tasks $APP"
echo "View output:   cf logs $APP --recent | grep issue-${ISSUE}"
echo "Watch the agent work on the issue itself at:"
echo "  https://github.com/${REPO}/issues/${ISSUE}"
