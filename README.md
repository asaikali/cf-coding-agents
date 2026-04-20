# cf-coding-agents

Experiments in running coding agents on Cloud Foundry as one-shot `cf task`
invocations rather than long-running web apps.

The repo walks through the same idea in two scenarios, so you can see both
how to package a pre-built agent *binary* and how to package an agent built
on the *SDK* — while the surrounding Cloud Foundry plumbing (system-tool
install, environment wiring, credential delivery) stays the same across
both.

## Scenarios

| Directory | Agent shape | Teaches |
|---|---|---|
| [`01-claude-cli/`](01-claude-cli/) | The Claude Code CLI binary, downloaded and run directly | Assembling a droplet with `apt-buildpack` for system tools, `.profile.d/` for environment wiring, a `binary_buildpack` release, and user-provided services for credentials. This is the foundation; read it first. |

Start with `01-claude-cli/` — everything it establishes carries over into
the later scenarios unchanged, so the story is additive rather than
parallel.
