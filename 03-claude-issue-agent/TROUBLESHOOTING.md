# Troubleshooting: Claude Agent SDK `query()` times out on Cloud Foundry

This document captures a genuine, reproducible bug we hit while wiring up
scenario 3 (and scenario 2) to the Claude Agent SDK's
`claude_agent_sdk.query()` entrypoint on Cloud Foundry. The bug is **not
fixed** at the time of writing; this file is a record of what's been
tried so the next debugging session doesn't start from zero.

## Summary

When `claude_agent_sdk.query()` runs inside a `cf run-task` on cflinuxfs4,
the SDK's `initialize` control request to the bundled `claude` CLI
subprocess times out after 60 seconds. The same Python code, same SDK
version, and same bundled binary **work correctly** on:

- The developer's macOS host
- A local Docker container based on `cloudfoundry/cflinuxfs4:latest`,
  running as the `vcap` user

The failure appears to be something environment-specific to the Cloud
Foundry task runtime, *not* to the rootfs image, user identity, binary,
SDK, Python version, or our code.

## Exact symptom

```
Exception: Control request timeout: initialize
```

Thrown from
`/home/vcap/deps/1/uv_venv/lib/python3.14/site-packages/claude_agent_sdk/_internal/query.py:434`
inside `_send_control_request`. Full traceback shows
`claude_agent_sdk._internal.client.process_query` →
`claude_agent_sdk._internal.query.initialize` →
`anyio.fail_after` raising `TimeoutError` after 60s.

With the CLI's `debug-to-stderr` flag enabled and a Python-side `stderr`
callback, we can see the subprocess complete its own startup (MDM
settings, CA certs, mTLS, Bootstrap fetch, Policy limits, MCP registry
load) and then go completely silent for the full 60s window. No bytes
arrive on its stdout, no further writes to stderr.

Last log line before the silence, reliably:

```
[cli] [DEBUG] [mcp-registry] Loaded 197 official MCP URLs (legacy)
```

## Minimum reproduction

### What runs
```python
import asyncio
from pathlib import Path
import claude_agent_sdk
from claude_agent_sdk import ClaudeAgentOptions, query

BUNDLED_CLI = str(Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude")

async def main():
    opts = ClaudeAgentOptions(
        allowed_tools=["Read", "Glob", "Grep"],
        cli_path=BUNDLED_CLI,
        setting_sources=[],
        permission_mode="bypassPermissions",
    )
    async for msg in query(prompt="say hello", options=opts):
        print(msg, flush=True)

asyncio.run(main())
```

### Environment
- cflinuxfs4 rootfs
- Python 3.14 installed by Tanzu's `python_buildpack`
- `claude-agent-sdk==0.1.63` installed from PyPI via `uv`
- Bundled binary: `claude_agent_sdk/_bundled/claude`, version `2.1.114`
- Invoked via `cf run-task agent-sdk --process task --command 'uv run python agent.py'`

### Outcome
Python `query()` times out at `initialize`; CF task reports `FAILED`.

## What works and what doesn't

| Environment | Python | Binary | Result |
|---|---|---|---|
| macOS (Apple Silicon), uv venv | 3.10 | Mach-O arm64 (bundled) | ✅ success in ~1–4 seconds |
| macOS, uv venv | 3.14 | Mach-O arm64 (bundled) | ✅ success |
| Docker `cloudfoundry/cflinuxfs4:latest`, as `vcap` (uid 2000), `--platform=linux/amd64` | 3.14 | ELF x86-64 (bundled) | ✅ success |
| Docker `cloudfoundry/cflinuxfs4:latest`, as `root` | 3.14 | ELF x86-64 (bundled) | ❌ explicit error: `--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons` |
| **Cloud Foundry `cf run-task` (task process) on cflinuxfs4**, as `vcap` | 3.14 | ELF x86-64 (bundled) | ❌ **`Control request timeout: initialize` after 60 seconds** |
| Cloud Foundry `cf run-task`, as `vcap` | 3.14 | ELF x86-64 (standalone download from `downloads.claude.ai`, same version 2.1.114) | ❌ same timeout |

The first two rows establish the SDK works. The third row proves the
bundled linux-x64 binary works in streaming mode under a cflinuxfs4
rootfs with the vcap user. The CF rows show the failure is
CF-runtime-specific rather than image-, binary-, or user-specific.

## The CLI-subprocess log sequence (on CF)

Captured with the CLI's `--debug-to-stderr` flag active, piped through
the Python SDK's `stderr` callback so it interleaves with Python stderr.
Abbreviated — the full log is ~200 lines of DEBUG messages, all of
which have exact analogues in the successful Docker run.

```
MDM settings load completed
Broken symlink or missing file encountered for settings.json at path: /etc/claude-code/managed-settings.json
CA certs: Config fallback
[init] configureGlobalMTLS starting / complete
[init] configureGlobalAgents starting / complete
CA certs: Loaded 145 bundled root certificates
mTLS: Creating HTTPS agent with custom certificates
[STARTUP] Loading MCP configs
[STARTUP] setup() completed in 6ms
Total LSP servers loaded: 0
Initialized versioned plugins system with 0 plugins
Remote settings: No settings found (404)
Policy limits: Fetched successfully
[Bootstrap] Fetch ok
Policy limits: Applied new restrictions successfully
Ripgrep first use test: PASSED (mode=embedded, path=…/claude_agent_sdk/_bundled/claude)
[mcp-registry] Loaded 197 official MCP URLs (legacy)
  ← 58 seconds of silence →
[Python side] Exception: Control request timeout: initialize
```

**Key observation**: the last non-error line from the CLI mentions
`[mcp-registry] Loaded 197 official MCP URLs (legacy)`. This is the
same point in the successful Docker run, except in Docker the CLI
proceeds to emit the SDK-init response on stdout, make its
`source=sdk` `/v1/messages` API call, and return messages.

On CF, none of those follow-up events ever happen.

## Investigation log

### 1. Fixed: `cli_path` pointing at the bundled binary

**Problem:** the SDK's default CLI discovery uses `shutil.which("claude")`
and a handful of common install paths (`~/.npm-global/bin/claude`,
`/usr/local/bin/claude`, `~/.local/bin/claude`, etc.) none of which
exist in the CF container. Without `cli_path`, the SDK raised
`CLINotFoundError`.

**Fix:** set `cli_path=str(Path(claude_agent_sdk.__file__).parent /
"_bundled" / "claude")`. This made the SDK spawn the subprocess.

**Status:** required, applied. Did not fix the timeout — it just moved
us from "can't spawn" to "can spawn but hangs on init."

### 2. Fixed: process-level resources in manifest

**Problem:** declaring `processes:` in a manifest prevents app-level
`memory`/`disk_quota` from cascading. Processes got default 1G/1G, and
the 1G disk was insufficient for the uv venv + bundled binary droplet
extraction.

**Fix:** set `memory` and `disk_quota` on the `task` process itself.
Use `cf run-task --process task --command '...'` so run-task inherits
those resources.

**Status:** required, applied. Prerequisite for getting the SDK to load
at all; unrelated to the initialize timeout.

### 3. Tested: `setting_sources=[]` + `permission_mode="bypassPermissions"`

The Python SDK documentation recommends these for CI / headless use:
- `setting_sources=[]` skips discovery of `~/.claude/settings.json`,
  `~/.claude/skills`, managed settings, and plugin sync.
- `permission_mode="bypassPermissions"` skips interactive permission
  prompts that have no UI in a CF task.

Passed both. The CLI log confirms they're applied
(`permissionMode: 'bypassPermissions'` appears in the init message on
the successful Docker run). Neither fixes the CF timeout.

### 4. Tested: `extra_args={"debug-to-stderr": None}` + stderr callback

Gave us the full debug stream from the bundled binary's stderr.
Confirmed the subprocess completes its own startup in ~2–3 seconds on
CF, then waits without reading stdin or writing stdout. No errors, no
crashes. Just silence.

### 5. Tested: Python-side `logging.basicConfig(level=logging.DEBUG, force=True)`

Surfaced three Python-side log lines (asyncio selector choice, agent
sentinel, OTEL trace context failure) and nothing else. Specifically,
no `[claude_agent_sdk._internal.message_parser] DEBUG: Skipping unknown
message type` was ever emitted — meaning the SDK's message-reader loop
never sees a single byte come back from the subprocess's stdout.
**Rules out "protocol mismatch silently swallowed."**

### 6. Tested: network reachability from inside a CF task

Ran a curl probe as a task:

- DNS for `api.anthropic.com` resolves to both IPv4 (`160.79.104.10`)
  and IPv6 (`2607:6bc0::10`).
- `curl https://api.anthropic.com/` returns HTTP 404 in ~100ms (TLS
  handshake works).
- Authenticated `POST /v1/messages` with the UPS-provided
  `ANTHROPIC_API_KEY` returns HTTP 200 with a real Claude response in
  ~1.3 seconds.
- `statsigapi.net` (auxiliary telemetry host) also reachable.

**Rules out** network egress, ASG firewall, DNS, and API key validity.

### 7. Tested: `ldd` on the bundled linux binary

All dynamic library dependencies resolved:
`librt.so.1`, `libc.so.6`, `libpthread.so.0`, `libdl.so.2`, `libm.so.6`.
Nothing says "not found."

**Rules out** missing system libraries.

### 8. Tested: `getaddrinfo` from inside a task

Python `socket.getaddrinfo("api.anthropic.com", 443, AF_UNSPEC, …)`
returns both IPv4 and IPv6 addresses. `/etc/nsswitch.conf` has
`hosts: files dns`. `/etc/gai.conf` is empty (glibc defaults).

Earlier `getent hosts` had only returned IPv6 which was a red herring.
**Rules out** IPv6-only DNS as a cause.

### 9. Tested: SDK version

Latest `claude-agent-sdk` on PyPI is `0.1.63` — we're already pulling
that via `>=0.1.0`. No newer version exists. Pinning to `==0.1.63` for
reproducibility.

**Rules out** stale version.

### 10. Tested: Python 3.14 vs 3.10 locally

Ran the same test locally on Mac with both Python 3.10 (default) and
Python 3.14 (same as CF's `python_buildpack` picks). Both succeed with
clean `SystemMessage(init)` → `AssistantMessage` → `ResultMessage`
returns in <5s.

**Rules out** Python 3.14 specifically.

### 11. Tested: `uv run` stdio wrapping

User hypothesis: CF captures the task's stdin/stdout for Loggregator,
and `uv run`'s stdio handling may propagate that somehow into the
subprocess pipes.

Test: bypass `uv run` — invoke the venv's Python binary directly:
`cf run-task agent-sdk --process task --command
'/home/vcap/deps/1/uv_venv/bin/python agent.py "say hello"'`.

**Result:** same timeout. **Rules out** `uv run`'s stdio handling.

### 12. Tested: scenario-1 standalone-downloaded binary instead of the
     SDK-wheel-bundled one

Both are Claude Code 2.1.114 but come from different build pipelines
(downloads.claude.ai vs the Python wheel). Swapped `cli_path` to
`./bin/claude` (the scenario-1 downloaded binary shipped with scenario
2's droplet).

**Result:** same timeout. **Rules out** the SDK-wheel packaging being
different from the direct-download build.

### 13. Tested: Docker `cloudfoundry/cflinuxfs4:latest` as `vcap` (the critical one)

Built a local Docker image using `cloudfoundry/cflinuxfs4:latest` as
the base, installed uv + the SDK, and ran as the `vcap` user
(`USER vcap`, uid 2000 — the same uid CF uses). Used
`--platform=linux/amd64` on Apple Silicon so Rosetta emulates the
linux-x64 binary architecture.

**Result:** ✅ **works**. Got
`AssistantMessage(content=[TextBlock(text="Hello! Hope you're having
a wonderful day! 👋")], …)` and a successful `ResultMessage` in 2.9
seconds.

This is the most important data point. **Same rootfs image, same user,
same binary, same Python, same code — works in Docker, hangs on CF.**

## Ruled out

Based on the above, all of the following are confirmed **not** the
cause:

- SDK protocol bug (works on multiple environments)
- `ClaudeAgentOptions` content
- Python 3.14 compatibility
- `uv run` / `uv`'s subprocess handling
- The SDK-bundled vs standalone download of the linux binary
- Missing library dependencies
- Network egress / firewall / ASGs
- DNS / IPv6 resolution quirks
- cflinuxfs4 rootfs itself
- The `vcap` user identity
- `permission_mode="bypassPermissions"` being rejected
- The API key

## Remaining suspects

These are the variables that still differ between our successful
Docker-cflinuxfs4-vcap run and the failing CF-cflinuxfs4-vcap run:

1. **Environment variables.** CF injects a bunch of runtime env vars
   (`VCAP_SERVICES`, `VCAP_APPLICATION`, `PORT`, `CF_INSTANCE_*`,
   `MEMORY_LIMIT`, `CLAUDECODE`?, etc.) that Docker doesn't. One or
   more of these might be read by the bundled Bun CLI and change its
   init behavior. The simplest next experiment is to `env` inside a CF
   task and inside Docker, diff, then selectively inject the CF-only
   vars into Docker to see which one triggers the hang.

2. **Container runtime differences.** CF uses Garden (runc under the
   hood with Diego-specific cgroup and namespace configs). Docker
   Desktop uses its own runtime. Differences in:
   - seccomp / AppArmor profile
   - cgroup v1 vs v2
   - Pipe buffer sizes (kernel param `pipe-max-size`)
   - PID namespace behavior
   - signal / process-reaper behavior (Diego uses a specific init process)

3. **Specific ordering inside the CLI startup.** On Docker the CLI
   emits `Stream started - received first chunk` (an inbound API
   streaming response) *before* `[mcp-registry] Loaded 197 official MCP
   URLs (legacy)`. On CF the MCP-registry line is the last thing
   emitted before the hang. Something may be racing that doesn't race
   in Docker.

4. **Filesystem mount types.** CF's task container mounts its writable
   layer with specific options Docker doesn't use. If the Bun binary
   does something that behaves differently on those mount types
   (memory-mapped temp files, `F_GETFL` on a pipe, etc.), this could
   manifest as a hang.

## Workarounds that we've intentionally **not** taken

The user explicitly wants to make the SDK's `query()` work on CF,
not paper over it. So none of the following have been applied:

- **Shelling out to `claude -p "<prompt>"` via `subprocess.run`.**
  Batch mode works on CF, but gives up the SDK's typed message stream
  and hook surface.
- **Falling back to scenario 1's binary-direct shape for scenario 3.**
  Loses the SDK-as-library story.

## Concrete next steps when resuming this debugging

In rough order of cost / signal:

1. **Env-var diff.** Capture `env` output in both a CF task and the
   Docker container. Diff. Identify CF-only vars. Inject them one by
   one (or in groups) into the Docker run via `-e`. When one of them
   reproduces the hang, we have the smoking-gun trigger.

2. **Try unsetting `VCAP_SERVICES`, `VCAP_APPLICATION`, `PORT`, and
   `CLAUDECODE` inside the task command** and see if any single unset
   makes the hang go away. (Equivalent to the above but from the other
   direction.)

3. **Run the SDK under `strace -e trace=read,write,close -p <pid>`**
   on the CF side if we can get `strace` installed via `apt.yml` and
   CF task permissions allow it. Would show whether the subprocess is
   reading stdin and/or writing stdout during the silence.

4. **File an upstream bug at `anthropics/claude-agent-sdk-python`**
   with the full repro. Given the Docker-cflinuxfs4 comparison point,
   this is a high-quality bug report: "the bundled Bun CLI's streaming
   init stalls under Diego/runc but not runc standalone."

5. **Instrument the SDK itself** (monkey-patch
   `subprocess_cli.py`'s stdin-write and stdout-read paths) to log
   every byte. Would tell us whether the Python side is actually
   writing the initialize JSON to the subprocess and whether the
   subprocess is writing anything back.

## Files of interest

- `03-claude-issue-agent/agent/agent.py` — production entrypoint,
  uses the SDK options we've tested (`cli_path`, `setting_sources=[]`,
  `permission_mode="bypassPermissions"`, stderr callback,
  `debug-to-stderr`, DEBUG-level Python logging).
- `03-claude-issue-agent/agent/smoke_test.py` — the read-only
  verification agent prompt. Same options; same failure.
- `03-claude-issue-agent/agent/debug_sdk.py` and
  `03-claude-issue-agent/agent/raw_probe.py` — diagnostic scripts we
  used during the investigation; kept in the tree for the next round.
- `03-claude-issue-agent/manifest.yaml` — task process has
  `memory: 2G` and `disk_quota: 8G`. `cf run-task --process task`
  inherits these.
- `03-claude-issue-agent/verify.sh` — runs `smoke_test.py` via
  `cf run-task --process task`.
- `/tmp/claude-501/claude-sdk-local/` (not in this repo) — the local
  test harness, including the Dockerfile that reproduces the
  successful case.

## State of `agent.py` at the time of writing

`agent.py` contains the full set of CI/headless options established
above. If a future debugging session proves that one of these options
is causative, update the file and this doc together.
