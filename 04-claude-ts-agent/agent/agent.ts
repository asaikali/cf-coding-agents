/**
 * Cloud Foundry task that works a GitHub issue into a pull request.
 *
 * TARGET_REPO is baked into the manifest. ISSUE_NUMBER is set per-invocation.
 * The agent drives gh, git, and ./mvnw through its Bash tool; the interesting
 * work lives in the prompt, not in orchestration code here.
 *
 * This is the TypeScript twin of 03-claude-issue-agent/agent/agent.py. If
 * scenario 3's Python SDK hits its Control request timeout: initialize bug,
 * the TS SDK — which uses Node's child_process + a different async model —
 * might sidestep it. Same bundled Bun binary underneath, so if the bug is
 * in the binary's stdio handling this scenario hangs the same way.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    process.stderr.write(`error: ${name} must be set in the environment\n`);
    process.exit(2);
  }
  return value;
}

function buildPrompt(repo: string, issue: string): string {
  return `
You are a coding agent working on issue #${issue} in the GitHub repo ${repo}.
Your goal is to implement what the issue asks for and open a pull request
that closes the issue.

Workflow:
1. Clone the repo into ./work:
     gh repo clone ${repo} ./work
2. cd ./work
3. Read the issue:
     gh issue view ${issue} --repo ${repo}
4. Post a comment on the issue acknowledging you've started and outlining
   your plan:
     gh issue comment ${issue} --repo ${repo} --body "..."
5. Create a working branch:
     git checkout -b agent/issue-${issue}
6. Implement the change. Keep it minimal and focused on the issue; do not
   refactor unrelated code.
7. Run the test suite: ./mvnw test
   If tests fail, investigate, fix, and re-run until they pass.
8. Commit with a descriptive message that references the issue.
9. Push the branch:
     git push -u origin agent/issue-${issue}
10. Open a pull request closing the issue:
     gh pr create --title "..." \\
       --body "Closes #${issue}\\n\\n<short summary of the change>"
11. Post a final comment on the issue with the PR URL and a short summary.

Comment etiquette: one comment when you start (with your plan), one at any
major decision point (for example, tests failing and what you're doing about
it), and one at the end (with the PR link). Enough trace to audit, not so
much it becomes noise.

If the issue is ambiguous, post a clarifying comment on the issue and stop.
Do not guess at the intent.
`;
}

async function main(): Promise<void> {
  const repo = requireEnv("TARGET_REPO");
  const issue = requireEnv("ISSUE_NUMBER");

  for await (const message of query({
    prompt: buildPrompt(repo, issue),
    options: {
      allowedTools: ["Bash", "Read", "Edit", "Glob", "Grep", "Write"],
      settingSources: [],
      permissionMode: "bypassPermissions",
      // Mirror of the Python-side stderr callback + debug-to-stderr extra_arg
      // that's been useful for diagnosing the CF init hang. Keep both so this
      // scenario produces the same debug-level detail as scenario 3 did.
      extraArgs: { "debug-to-stderr": null },
      stderr: (line: string) =>
        process.stderr.write(`[cli] ${line}\n`),
    },
  })) {
    console.log(JSON.stringify(message));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
