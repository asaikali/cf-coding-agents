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
| [`03-claude-issue-agent/`](03-claude-issue-agent/) | An SDK-driven agent that treats GitHub issues as prompts and opens a PR closing each one | Extending scenario 2 into a real coding workflow: a thin Python wrapper hands the SDK a prompt that tells it to clone the target repo, read the issue, implement, test, commit, push, and open a PR — using `gh` and `git` through its `Bash` tool. Shows how little glue is needed around the SDK once the droplet has the right tools and credentials. Runs against a forked [Spring PetClinic](https://github.com/asaikali/spring-petclinic). |
| [`04-claude-ts-agent/`](04-claude-ts-agent/) | Scenario 3's same workflow re-implemented against the **TypeScript** Claude Agent SDK with `nodejs_buildpack` | Isolates whether the SDK-initialize hang documented in `03-claude-issue-agent/TROUBLESHOOTING.md` is Python-library-specific or lives in the bundled CLI binary. Same agent prompt, same options, same UPS secrets, same target repo — only the language and release buildpack differ. |

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

Every scenario needs two secrets: an **Anthropic API key** for the
model, and a **GitHub token** for `gh` and for `git` over HTTPS.
Neither is baked into the droplet; neither lives in a tracked file in
this repo.

#### Why user-provided services instead of manifest env

Passing secrets via `cf push --var` puts them on the command line —
visible in argv, shell history, and any `set -x` output, and they
travel with every subsequent push. Cloud Foundry's idiomatic answer is
a **user-provided service** (UPS): the secret is handed to CF once,
outside of any push, and the app binds the service by name.

We use **two separate services** — `anthropic-creds` and `github-creds`
— rather than one combined blob so each credential can rotate and be
shared with other apps independently.

#### What the `cf` commands look like

Creating each secret as its own UPS is one command per service:

```sh
cf create-user-provided-service anthropic-creds -p '{"api_key":"..."}'
cf create-user-provided-service github-creds    -p '{"token":"..."}'
```

`cf cups` takes either a literal JSON string (as above) or a path to a
JSON file. Each scenario's `create-services.sh` picks the form that
keeps secret material off the command line; see the scripts for the
details of where the values come from on your laptop.

The manifest declares the bindings:

```yaml
services:
  - anthropic-creds
  - github-creds
```

That's all `cf push` knows about credentials — no `--var` passes, no
secret arguments.

Rotating a value is `cf update-user-provided-service <name> -p <json>`
— no re-push needed; the next task invocation reads the fresh value.

#### Inside the container

CF injects a single env var, `VCAP_SERVICES`, whose value is a JSON
blob with every bound service and its credentials. The agent tools
(`gh`, the Anthropic SDK) expect flat env vars like `ANTHROPIC_API_KEY`
and `GH_TOKEN`, not a JSON blob. Every scenario ships a
`.profile.d/vcap.sh` that runs before every task, parses
`VCAP_SERVICES` with `jq`, and re-exports the two values under the
names the tools read. `cf env` redacts the secrets in all output.
