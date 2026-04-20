# 02-claude-python-sdk

Scenario 2: run a coding agent on Cloud Foundry as a `cf task`, but
instead of shipping the Claude Code CLI binary we depend on the
[Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview)
from Python and launch the agent from our own entry script. See the
[root README](../README.md) for the shared Cloud Foundry mechanics
(`apt-buildpack`, `.profile.d/`, user-provided services); this README
covers only what's different here.

## What changes vs scenario 1

The only genuinely new parts are the **agent payload** and the
**release buildpack** — everything else is identical to
`01-claude-cli/`.

- **Payload:** `pyproject.toml` + `uv.lock` + `agent.py` replace the
  downloaded CLI binary. The agent is a small async Python program
  that calls the SDK's `query()` and streams messages back; the SDK
  handles the tool-execution loop.
- **Release buildpack:** `python_buildpack` replaces `binary_buildpack`.
  Tanzu's Python buildpack reads `pyproject.toml` and `uv.lock`
  natively, installs the declared dependencies with `uv`, and gives
  us `uv run` in the task environment.
- **What's identical:** `apt-buildpack` still installs system tools
  from `apt.yml`; `.profile.d/vcap.sh` still parses `VCAP_SERVICES`
  and re-exports `ANTHROPIC_API_KEY` / `GH_TOKEN`; both user-provided
  services (`anthropic-creds`, `github-creds`) hold the same secrets
  — if you already created them for scenario 1 you can skip the
  create step and bind them directly.

## Layout

```
02-claude-python-sdk/
├── manifest.yaml           ← has `path: ./agent`, so cf push uploads only that dir
├── push.sh                 ← wraps `cf push` — stays on your laptop
├── cleanup.sh              ← tears down the app and services
├── create-services.sh      ← creates/updates the user-provided services
├── verify.sh               ← submits a cf run-task that invokes agent/versions.sh
└── agent/                  ← exactly what ends up in the droplet
    ├── apt.yml             ← apt-buildpack reads this at the uploaded tree's root
    ├── pyproject.toml      ← python_buildpack resolves dependencies from this
    ├── uv.lock             ← committed for reproducible installs
    ├── agent.py            ← the task entry that calls the SDK
    ├── versions.sh         ← baked-in smoke test
    └── .profile.d/         ← sourced by CF's launcher before every task
        └── vcap.sh
```

## Running it

```sh
./create-services.sh        # first time only; or run scenario 1's version
./push.sh                   # build droplet, stage, leave stopped
cf run-task agent-py --command 'uv run python agent.py "your prompt"'
cf logs agent-py --recent
```

## Notes

- **Lockfile.** `uv.lock` is committed so `python_buildpack` resolves
  deterministically rather than pulling fresh versions on each push.
  Regenerate with `uv lock` from inside `agent/` when dependencies
  change.
- **Prompt surface.** `agent.py` currently takes one positional
  argument as the prompt. Whether you want the task to read from stdin,
  a file, or a richer invocation pattern is scenario-specific.
