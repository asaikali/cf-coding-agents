---
name: github-issue-workflow
description: Implement a GitHub issue as a pull request. Clone the
  target repo, read the issue, make the change, run the project's
  tests, push a branch, open a PR that closes the issue, and comment
  on the issue at key points along the way. The caller will tell you
  which repo and which issue number to work on.
---

# GitHub Issue → Pull Request

You are a coding agent whose goal is to implement what a GitHub issue
asks for and open a pull request that closes it. The caller will name
the target repo (as `<owner>/<name>`) and the issue number in the
prompt that invokes this skill; use those values wherever this skill
says `<repo>` or `<issue>`.

## Workflow

1. Clone the repo into `./work`:
     `gh repo clone <repo> ./work`
2. `cd ./work`
3. Read the issue:
     `gh issue view <issue> --repo <repo>`
4. Post a comment on the issue acknowledging you've started and
   outlining your plan:
     `gh issue comment <issue> --repo <repo> --body "..."`
5. Create a working branch:
     `git checkout -b agent/issue-<issue>`
6. Implement the change. Keep it minimal and focused on what the
   issue asks for; do not refactor unrelated code.
7. Run the project's test suite. Pick the right command for the
   project — `./mvnw test`, `./gradlew test`, `npm test`, `pytest`,
   `go test ./...`, etc. If tests fail, investigate, fix, and re-run
   until they pass.
8. Commit with a descriptive message that references the issue.
9. Push the branch:
     `git push -u origin agent/issue-<issue>`
10. Open a pull request closing the issue:
     `gh pr create --title "..." --body "Closes #<issue>\n\n<short summary>"`
11. Post a final comment on the issue with the PR URL and a short
    summary of what changed.

## Comment etiquette

Post one comment when you start (with your plan), one at any major
decision point (for example, tests failing and what you're doing
about it), and one at the end (with the PR link). Enough trace for a
reviewer to audit your work, not so much it becomes noise.

## Ambiguity

If the issue is unclear or under-specified, post a clarifying comment
on the issue and stop. Do not guess at the intent.

## Scope discipline

This skill implements **one** issue as **one** PR. Don't pick up
related improvements you spot along the way; if they're worth doing,
they're worth their own issues.
