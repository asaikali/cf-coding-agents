# 02-claude-python-sdk

Scenario 2: run a coding agent on Cloud Foundry as a `cf task`, but instead
of shipping the Claude Code CLI binary we depend on the [Claude Agent
SDK](https://code.claude.com/docs/en/agent-sdk/overview) from Python and
launch the agent from our own entry script.

## How this differs from scenario 1

Everything you learned in `01-claude-cli/` carries over unchanged:

- **`apt-buildpack`** still installs the system tools the agent needs
  (`gh`, `ripgrep`, and whatever else you add to `apt.yml`).
- **`.profile.d/vcap.sh`** still parses `VCAP_SERVICES` and re-exports
  `ANTHROPIC_API_KEY` and `GH_TOKEN` so the SDK and `gh` find them.
- **Two user-provided services** (`anthropic-creds`, `github-creds`) still
  hold the secrets. `create-services.sh` has the same shape — in fact, if
  you already created them for scenario 1 you can skip this step.
- **The manifest still declares a task-only app** with `no-route: true` and
  a stopped `web` process.

The only genuinely new part is the **release buildpack**. Scenario 1 used
`binary_buildpack` to run a pre-built executable; here we use Tanzu's
`python_buildpack`, which reads `pyproject.toml` (and `uv.lock` if present)
and installs the declared dependencies with `uv`. The agent itself is
`agent.py`, which uses the Claude Agent SDK's `query()` call to run a
prompt end-to-end — the SDK handles the tool-execution loop.

## Layout

Scenario 2 splits "what gets deployed" from "what you run to deploy it":

```
02-claude-python-sdk/
├── manifest.yaml           ← has `path: ./agent`, so cf push uploads only that dir
├── push.sh                 ← wraps `cf push` — stays on your laptop
├── cleanup.sh              ← tears down the app and services
├── create-services.sh      ← creates/updates the user-provided services
└── agent/                  ← exactly what ends up in the droplet
    ├── apt.yml             ← apt-buildpack reads this at the uploaded tree's root
    ├── pyproject.toml      ← python_buildpack resolves dependencies from this
    ├── agent.py            ← the task entry that calls the SDK
    └── .profile.d/         ← sourced by CF's launcher before every task
        └── vcap.sh
```

`apt.yml` and `.profile.d/` live inside `agent/` because both are read
*inside the droplet* — `apt-buildpack` scans the uploaded tree's root for
`apt.yml`, and CF's launcher sources `<app_root>/.profile.d/*.sh` before
every task command. The manifest and shell scripts live outside `agent/`
because they're read **on your laptop**, by the CF CLI, and don't need to
ride along into the container.

## Running it

```sh
./create-services.sh        # first time only; or run scenario 1's version
./push.sh                   # build droplet, stage, leave stopped
cf run-task agent-py --command 'uv run python agent.py "your prompt"'
cf logs agent-py --recent
```

## Two things to sort out when you build on this scaffold

- **Lockfile.** Run `uv lock` locally and commit `uv.lock` so the buildpack
  resolves deterministically rather than pulling fresh versions on each
  push.
- **Prompt surface.** `agent.py` currently takes one positional argument as
  the prompt. Whether you want the task to read from stdin, a file, or a
  richer invocation pattern is scenario-specific.
