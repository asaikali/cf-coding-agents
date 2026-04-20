# cf-coding-agents

Experiments in running coding agents on Cloud Foundry as one-shot `cf task`
invocations rather than long-running web apps. Each scenario is a worked
example showing what it takes to package, deploy, and authenticate a coding
agent as a task-only app.

## Why tasks?

A coding agent isn't a server. It wakes up, works against a prompt, and
exits. `cf task` matches that shape: stage the droplet once, then fire any
number of ad-hoc invocations against it with their own command, memory,
and disk. No route, no web process, no idle instance burning resources
between runs.

## Scenarios

| Directory | Agent shape | Demonstrates |
|---|---|---|
| [`01-claude-cli/`](01-claude-cli/) | The Claude Code CLI binary, downloaded and run directly | Driving a droplet with the `apt-buildpack` + `binary_buildpack` chain: fetch the agent binary, install a third-party JDK and Node LTS via extra apt repositories, wire environment with `.profile.d/`, deliver secrets via user-provided services. |
| [`02-claude-python-sdk/`](02-claude-python-sdk/) | A Python agent built on the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview), resolved by uv | Keeping every pattern from scenario 1 and swapping only the release buildpack to Tanzu's `python_buildpack`, which reads `pyproject.toml` and `uv.lock` natively. Shows what actually changes when the agent is a library instead of a binary. |

Start with `01-claude-cli/` — the patterns it establishes apply to every
scenario that follows; later scenarios only change the agent payload.

## Shared concepts

Each scenario has its own directory-specific details (what's in `apt.yml`,
what the task command runs, what payload lives inside `agent/`), but the
Cloud Foundry mechanics below apply to every scenario in this repo.

### How the toolbox is built with `apt-buildpack`

`apt-buildpack` is a Cloud Foundry buildpack that installs Debian/Ubuntu
packages into the droplet at staging time. We drive it with a small
declarative `apt.yml` listing the packages the agent needs — git, language
runtimes, anything the agent might shell out to — and the buildpack
fetches and unpacks them into the container.

Out of the box the buildpack pulls from the package repositories that
back the CF stack (cflinuxfs4 → Ubuntu Jammy). For packages that aren't
in those default repos, the same `apt.yml` also accepts extra GPG keys
and third-party apt sources, so any vendor that publishes a Debian
repository can be pulled in the same way.

`apt-buildpack` is chained **ahead** of the release buildpack in the
manifest. This matters: only the last buildpack in the chain owns the
release/start contract and decides how the app launches. `apt-buildpack`'s
job ends at "everything you declared is installed"; the release buildpack
remains responsible for launching the agent. Installed files land under a
well-known dependencies directory inside the droplet. Some Debian
packages put their binaries straight on `PATH`; others expect
`update-alternatives` symlinks that are only created on a full Debian
install and therefore need a little environment wiring (see `.profile.d/`
below).

### What the stack already ships, and what we add

Before adding anything to `apt.yml`, check what cflinuxfs4 already
includes. The authoritative list lives in the stack's repo at
[`cloudfoundry/cflinuxfs4`](https://github.com/cloudfoundry/cflinuxfs4/blob/main/packages/cflinuxfs4).
Listing a package that's already in the base stack just inflates the
droplet and slows staging for no functional gain.

cflinuxfs4 gives us a lot of the basics for free — among them `git`,
`jq`, `unzip`/`zip`, `build-essential` (gcc, g++, make),
`ca-certificates`, `curl`, `wget`, `openssl`, and the usual diagnostic
utilities. None of those appear in any scenario's `apt.yml`. Each
scenario's README documents the specific packages it *does* install and
why.

### Wiring environment with `.profile.d/`

Some tools installed via `apt-buildpack` need extra environment setup
before they're usable — the agent might expect `JAVA_HOME` set, or a
binary located outside the default `PATH`. Rather than bake that into
every task command, we rely on Cloud Foundry's `.profile.d/` convention.

Any `*.sh` file in a `.profile.d/` directory at the root of the pushed
app is uploaded with the droplet (CF includes dotfiles by default,
respecting only `.cfignore`) and **sourced by CF's launcher before any
start command runs** — whether that's the declared task process or an
ad-hoc `cf run-task --command`. Each invocation gets a fresh shell, so
there's no cross-task leakage, and exported variables are inherited by
the agent and everything it forks.

This gives us a single, file-based place to bind buildpack-installed
tools into the container's environment, without touching the manifest,
the task command, or the buildpack itself.

### How credentials reach the agent

Every scenario needs two secrets: an **Anthropic API key** so the model
can be called, and a **GitHub token** so the agent can read issues, open
PRs, and push branches. Neither is baked into the droplet, and neither
lives in a tracked file in this repo.

#### Why user-provided services instead of manifest env

The natural first approach — pass each secret as a `cf push --var` and
land it in the manifest's `env:` block — has a subtle but real leak:
every value passed to `cf push --var` is an argument on the CLI command
line, so it appears in the process's argv, in shell history, and in
anything that echoes the invoked command (like a script with `set -x`).
The secret also travels with every subsequent push.

Cloud Foundry's idiomatic answer for secrets is a **user-provided
service** (UPS). The secret is handed to CF once, outside of the push,
via a separate `cf` command that reads its JSON payload from a file path
— not from an inline CLI argument — so the secret never appears in argv
or shell history. The app binds the service by name in the manifest;
inside the container the secret appears in the `VCAP_SERVICES` JSON
blob, which `cf env` redacts. Pushes themselves carry no secret material
at all.

We use **two separate services** — `anthropic-creds` and `github-creds`
— rather than one combined blob so each credential can rotate and be
shared with other apps independently.

#### The flow

1. **The secrets live on the developer's laptop.** The Anthropic key is
   expected in a shell environment variable. The GitHub token is sourced
   live from `gh`'s own secure storage (on macOS, the system Keychain) —
   whatever `gh` is logged in as locally is what the laptop carries.
2. **A small setup script publishes them into CF services.** A shell
   script reads both secrets locally and passes each one to
   `cf create-user-provided-service` (or `cf update-user-provided-service`
   when rotating) through a bash process substitution — an in-memory
   pipe that gives `cf` a file-like `/dev/fd/...` path to read the JSON
   from, so the secret lives only in memory and never hits argv or disk.
   Rotation is just re-running the script in update mode; no `cf push`
   needed.
3. **The manifest binds the services by name.** `cf push` itself passes
   no secret arguments; it just declares which services the app
   consumes.
4. **The container hoists them into env vars the tools expect.** A
   `.profile.d/` script parses `VCAP_SERVICES` at the start of every
   task invocation, exports `ANTHROPIC_API_KEY` and `GH_TOKEN`, and runs
   `gh auth setup-git` so raw `git clone`/`push` over HTTPS use the same
   token as `gh` without any extra wiring. From the agent's perspective
   the environment looks identical to the simpler env-var design; the
   difference is entirely upstream.

Because the GitHub token is fetched live from `gh`'s local storage each
time the setup script runs, rotation is essentially free: re-login with
`gh` or rotate the token in GitHub's UI, then re-run the setup script.
The next task invocation picks up the new value on its own.

The scoping of the token is inherited from whatever the laptop's `gh`
session has — fine for local experimentation. For a more
production-shaped setup, the same service contract works with a
fine-grained PAT scoped to specific repos, or with a short-lived GitHub
App installation token refreshed by an external process.
