# cf-coding-agents

Experiments in running coding agents (e.g. Claude Code) on Cloud Foundry as
one-shot `cf task` invocations rather than long-running web apps.

## Why tasks?

A coding agent isn't a server. It wakes up, works against a prompt, and exits.
`cf task` matches that shape: stage the droplet once, then fire any number of
ad-hoc invocations against it with their own command, memory, and disk. No
route, no web process, no idle instance burning resources between runs.

## Approach

1. **Download the agent binary.** A small script fetches the Linux build of the
   coding agent that matches the CF stack, so the droplet ships the exact
   version we intend to run.
2. **Layer on the tools the agent needs.** Coding agents typically shell out
   to developer tooling (git, compilers, package managers, etc.). We use the
   `apt-buildpack` to install those OS packages into the container, chained
   ahead of the `binary_buildpack` that launches the agent. The agent binary
   and its surrounding toolbox are baked into the same droplet.
3. **Push as a task-only app.** The manifest declares no route and no running
   web process; the app is staged and left stopped. Work happens on demand via
   `cf run-task`, which runs the agent against a prompt inside a fresh
   container and tears it down when it exits.

This keeps the CF surface area small (one app, one droplet) while letting each
agent invocation be independent, isolated, and cheap.
