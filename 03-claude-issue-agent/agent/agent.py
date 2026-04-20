"""Cloud Foundry task that works a GitHub issue into a pull request.

TARGET_REPO is baked into the manifest. ISSUE_NUMBER is set per-invocation,
typically via:

    cf run-task agent-issue \\
      --command 'ISSUE_NUMBER=42 uv run python agent.py'

The agent drives gh, git, and ./mvnw through its Bash tool. The interesting
work lives in the prompt below, not in Python orchestration code here.
"""

import asyncio
import os
import sys
from pathlib import Path

import claude_agent_sdk
from claude_agent_sdk import ClaudeAgentOptions, query

# The Python SDK's default search path for the claude CLI looks at shutil.which
# and a handful of common install locations (npm global, ~/.local/bin, etc.),
# none of which are present in the droplet. Point it at the binary the SDK
# ships with itself, under claude_agent_sdk/_bundled/claude.
BUNDLED_CLI = str(Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude")


def get_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.stderr.write(f"error: {name} must be set in the environment\n")
        sys.exit(2)
    return value


def build_prompt(repo: str, issue: str) -> str:
    return f"""
You are a coding agent working on issue #{issue} in the GitHub repo {repo}.
Your goal is to implement what the issue asks for and open a pull request
that closes the issue.

Workflow:
1. Clone the repo into ./work:
     gh repo clone {repo} ./work
2. cd ./work
3. Read the issue:
     gh issue view {issue} --repo {repo}
4. Post a comment on the issue acknowledging you've started and outlining
   your plan:
     gh issue comment {issue} --repo {repo} --body "..."
5. Create a working branch:
     git checkout -b agent/issue-{issue}
6. Implement the change. Keep it minimal and focused on the issue; do not
   refactor unrelated code.
7. Run the test suite: ./mvnw test
   If tests fail, investigate, fix, and re-run until they pass.
8. Commit with a descriptive message that references the issue.
9. Push the branch:
     git push -u origin agent/issue-{issue}
10. Open a pull request closing the issue:
     gh pr create --title "..." \\
       --body "Closes #{issue}\\n\\n<short summary of the change>"
11. Post a final comment on the issue with the PR URL and a short summary.

Comment etiquette: post one comment when you start (with your plan), one
at any major decision point (for example, tests failing and what you're
doing about it), and one at the end (with the PR link). Enough trace to
audit, not so much it becomes noise.

If the issue is ambiguous, post a clarifying comment on the issue and
stop. Do not guess at the intent.
"""


async def main() -> None:
    repo = get_env("TARGET_REPO")
    issue = get_env("ISSUE_NUMBER")

    options = ClaudeAgentOptions(
        allowed_tools=["Bash", "Read", "Edit", "Glob", "Grep", "Write"],
        cli_path=BUNDLED_CLI,
    )

    async for message in query(prompt=build_prompt(repo, issue), options=options):
        print(message, flush=True)


if __name__ == "__main__":
    asyncio.run(main())
