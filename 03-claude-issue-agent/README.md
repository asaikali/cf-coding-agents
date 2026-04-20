# 03-claude-issue-agent

Scenario 3: a coding agent that picks up a **GitHub issue**, implements the
requested change against the target repo, runs the tests, and opens a
**pull request** that closes the issue — posting progress comments on the
issue as it goes. See the [root README](../README.md) for the shared Cloud
Foundry mechanics (`apt-buildpack`, `.profile.d/`, user-provided services);
this README covers only what's specific to this scenario.

The target repo is hard-wired via manifest env to
[`asaikali/spring-petclinic`](https://github.com/asaikali/spring-petclinic),
a fork of the Spring sample app. Swap `TARGET_REPO` in `manifest.yaml` to
point the same droplet at a different repo.

## What changes vs scenario 2

- **Agent payload** — `agent.py` is no longer a trivial `query()`; it builds
  a prompt from `TARGET_REPO` + `ISSUE_NUMBER` and hands a focused workflow
  to the SDK: clone, read the issue, plan, branch, implement, test, commit,
  push, PR, comment. The agent drives `gh`, `git`, and `./mvnw` through its
  `Bash` tool — the Python code on our side is tiny.
- **Droplet needs a JDK** — `apt.yml` adds `temurin-25-jdk` (plus the
  Adoptium apt repo) and a `.profile.d/java.sh` shim that exports
  `JAVA_HOME`. Maven itself is not installed; Spring PetClinic ships a
  Maven wrapper (`./mvnw`) that bootstraps Maven on first run.
- **Larger task resources** — the task process in `manifest.yaml` declares
  `memory: 2G` and `disk_quota: 8G` to accommodate the JVM, the Maven
  `.m2` cache, the uv virtualenv, and the PetClinic build. Resources are
  set on the task process specifically rather than at app level because
  CF does not cascade app-level `memory`/`disk_quota` onto processes when
  a `processes:` block is declared.
- **What's identical** — `apt-buildpack` + `python_buildpack` chain,
  `.profile.d/vcap.sh` parsing `VCAP_SERVICES`, the two user-provided
  services (`anthropic-creds`, `github-creds`), and the task-only app
  shape. Services are shared across all scenarios in this repo.

## Layout

Same shape as scenario 2: the scenario root holds `manifest.yaml` and the
laptop-side shell scripts; `agent/` holds everything `cf push` uploads.
`agent.py` is the task entrypoint; `apt.yml`, `pyproject.toml`/`uv.lock`,
`.profile.d/`, and `versions.sh` play the roles they do in scenario 2.

## Running it

One-time setup (skip the first step if you already ran it for scenario 1
or 2):

```sh
./create-services.sh
./push.sh
./verify.sh                  # smoke-test the droplet end-to-end
```

Then, per issue, invoke the agent through the task process so it inherits
the 2G/8G resources:

```sh
cf run-task agent-issue \
  --process task \
  --command 'ISSUE_NUMBER=1 uv run python agent.py' \
  --name issue-1

cf logs agent-issue --recent
```

Watch the agent's progress on the issue itself at
`https://github.com/<TARGET_REPO>/issues/<ISSUE_NUMBER>`. The comment
thread is the live log; `cf logs` gets you the raw stream.

## Notes

- **The prompt is where the interesting work lives.** `agent.py` is ~60
  lines; the workflow is a few paragraphs of English instructing the SDK
  how to behave. Tuning agent behavior mostly means tuning the prompt, not
  rewriting Python.
- **Comment etiquette** is encoded in the prompt: one comment on start,
  one at any major decision point, one at the end. Enough trace to audit;
  not so much it becomes noise.
- **Ambiguous issues** are supposed to trigger a clarifying comment
  instead of a guessed implementation. If the agent gets this wrong,
  that's a prompt-engineering signal.
- **Task time** depends on PetClinic test runtime (30s–3min) and how many
  iterations the agent needs. Allow generously; a CF task's default
  timeout is typically an hour.
- **The `./mvnw` wrapper** downloads Maven on first run, so the first
  invocation on a fresh droplet takes longer than subsequent ones.
