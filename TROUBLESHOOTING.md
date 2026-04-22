# Claude Agent SDK on Cloud Foundry — bug investigation and workaround

## TL;DR

- The **Python** Claude Agent SDK (`claude-agent-sdk`) hangs at
  `initialize` when running inside a `cf run-task` on cflinuxfs4.
- The **TypeScript** Claude Agent SDK
  (`@anthropic-ai/claude-agent-sdk`) works correctly on the same CF
  environment.
- Scenario 4 (`04-claude-ts-agent/`) is the working path. Scenarios 2
  and 3 hit the Python bug and stay broken until the upstream SDK
  fixes it.

Root cause of the Python failure: the Python SDK spawns a bundled
native Bun binary (`claude_agent_sdk/_bundled/claude`, a 236MB ELF
x86-64 executable) as a subprocess and communicates with it via
stream-json over stdio pipes. That subprocess's stdio handshake hangs
under CF's Diego/runc task runtime. The TypeScript SDK takes a
different architectural path — it ships `cli.js` (11MB of JavaScript)
and runs the CLI in-process under Node.js, with no native subprocess
and no stdio handshake to fail — so it sidesteps the bug entirely.

If you need the SDK on CF today, **use scenario 4's approach**
(TypeScript + `nodejs_buildpack`). If you need the Python SDK
specifically, see "Investigation log" for everything tried and
"Remaining suspects" for what hasn't.

## Scenarios in this repo and their state

| Scenario | SDK path | CF behavior |
|---|---|---|
| [`01-claude-cli/`](01-claude-cli/) | No SDK; runs the Claude Code CLI binary directly via `-p` batch mode | ✅ works |
| [`02-claude-python-sdk/`](02-claude-python-sdk/) | Python SDK, trivial hello query | ❌ `Control request timeout: initialize` |
| [`03-claude-issue-agent/`](03-claude-issue-agent/) | Python SDK, GitHub-issue-to-PR agent workflow | ❌ same timeout as scenario 2 |
| **[`04-claude-ts-agent/`](04-claude-ts-agent/)** | **TypeScript SDK, same GitHub-issue-to-PR workflow as scenario 3** | **✅ SDK works end-to-end. Currently blocked on a separate Maven CA-trust issue at the Spring PetClinic compile step — unrelated to the SDK.** |

Scenarios 2 and 3 are left in the tree in their configured-but-broken
state. Their `agent.py` contains the full set of CI/headless options
we validated (`cli_path`, `setting_sources=[]`,
`permission_mode="bypassPermissions"`, stderr callback,
`debug-to-stderr`, `logging.basicConfig(level=logging.DEBUG,
force=True)`) — none fix the hang, but they're the right starting
state when the upstream bug gets fixed.

## Architectural difference between the two SDKs

This is the thing that took ~60 experiments to figure out.

### Python SDK

```
Python agent.py
  └── spawns subprocess: claude_agent_sdk/_bundled/claude  (236MB ELF, Bun native)
         stdin/stdout as pipes; --input-format stream-json --output-format stream-json
         Python writes a control_request:initialize JSON to stdin,
         waits for a control_response:initialize on stdout.
```

On CF: the subprocess starts, completes its own init up through the
`[mcp-registry] Loaded 197 official MCP URLs (legacy)` log line, then
sits silent. No bytes flow on stdin or stdout for 60 seconds. Python
SDK raises `Exception: Control request timeout: initialize`.

### TypeScript SDK

```
Node agent.ts (via tsx)
  └── imports @anthropic-ai/claude-agent-sdk
       └── loads cli.js  (11MB JavaScript file)
           runs in the same Node process — no subprocess, no pipes
```

On CF: the CLI runs in-process under Node, no stdio handshake ever
happens, no hang.

That's the entire story. The Python SDK's code path goes through the
native subprocess; the TS SDK's doesn't. Whatever's wrong with the
subprocess's stdio under CF's task runtime simply doesn't apply.

## Exact symptom (Python SDK)

```
Exception: Control request timeout: initialize
```

Thrown from `.../claude_agent_sdk/_internal/query.py:434` inside
`_send_control_request`. Full traceback goes
`claude_agent_sdk._internal.client.process_query` →
`claude_agent_sdk._internal.query.initialize` →
`anyio.fail_after` raising `TimeoutError` after 60s.

With the CLI's `debug-to-stderr` flag enabled and a Python-side
`stderr` callback, we see the subprocess complete its own startup
(MDM settings, CA certs, mTLS, Bootstrap fetch, Policy limits, MCP
registry load) and then go completely silent for the full 60s window.

Last log line before the silence, reliably:

```
[cli] [DEBUG] [mcp-registry] Loaded 197 official MCP URLs (legacy)
```

## Minimum reproduction (Python SDK)

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

### Environment for repro

- cflinuxfs4 rootfs
- Python 3.14 installed by Tanzu's `python_buildpack`
- `claude-agent-sdk==0.1.63` installed from PyPI via `uv`
- Bundled binary: `claude_agent_sdk/_bundled/claude`, version `2.1.114`
- Invoked via `cf run-task <app> --process task --command 'uv run python agent.py'`

## What works and what doesn't

| Environment | SDK | Result |
|---|---|---|
| macOS, uv venv, Python 3.10 | Python | ✅ success in ~1–4s (Mach-O arm64 bundled binary) |
| macOS, uv venv, Python 3.14 | Python | ✅ success |
| Docker `cloudfoundry/cflinuxfs4:latest`, `--platform=linux/amd64`, as `vcap` (uid 2000), Python 3.14 | Python | ✅ success (ELF x86-64 bundled binary) |
| Docker `cloudfoundry/cflinuxfs4:latest`, as `root` | Python | ❌ explicit error: `--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons` |
| **Cloud Foundry `cf run-task`, as `vcap`**, Python 3.14 | **Python** | ❌ **`Control request timeout: initialize` after 60s** |
| Cloud Foundry `cf run-task`, as `vcap`, standalone-downloaded binary from `downloads.claude.ai` (same version 2.1.114) | Python | ❌ same timeout |
| **Cloud Foundry `cf run-task`, as `vcap`** | **TypeScript** | **✅ SDK init completes in <2s, agent runs to completion** |

The Mac and Docker rows established that the Python SDK and bundled
binary work elsewhere, which initially suggested a CF-runtime-specific
bug. The final TypeScript row on CF reframed the conclusion: the
binary/subprocess-stdio code path is the issue; running the CLI
in-process (as the TS SDK does) dodges the CF runtime's interaction
entirely.

## The CLI-subprocess log sequence (Python SDK on CF)

Captured with the CLI's `--debug-to-stderr` flag active, piped
through the Python SDK's `stderr` callback. Abbreviated — the full
log is ~200 lines of DEBUG messages, all of which have exact
analogues in the successful Docker-cflinuxfs4 run.

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

On Docker-cflinuxfs4 the CLI proceeds from this point to emit the
SDK-init response on stdout, make its `source=sdk` `/v1/messages`
API call, and return `AssistantMessage` / `ResultMessage`. On CF,
none of those follow-up events ever happen.

## Investigation log

Fourteen experiments, chronological. Every hypothesis-test-result is
preserved for future reference and for anyone writing an upstream bug
report.

### 1. Fixed: `cli_path` pointing at the bundled binary

**Problem:** the SDK's default CLI discovery uses
`shutil.which("claude")` and a handful of common install paths
(`~/.npm-global/bin/claude`, `/usr/local/bin/claude`,
`~/.local/bin/claude`, etc.) none of which exist in the CF container.
Without `cli_path`, the SDK raised `CLINotFoundError`.

**Fix:** set `cli_path=str(Path(claude_agent_sdk.__file__).parent /
"_bundled" / "claude")`. This made the SDK spawn the subprocess.

**Status:** required, applied. Did not fix the timeout — it just
moved us from "can't spawn" to "can spawn but hangs on init."

### 2. Fixed: process-level resources in manifest

**Problem:** declaring `processes:` in a manifest prevents app-level
`memory`/`disk_quota` from cascading. Processes got default 1G/1G,
and the 1G disk was insufficient for the uv venv + bundled binary
droplet extraction.

**Fix:** set `memory` and `disk_quota` on the `task` process itself.
Use `cf run-task --process task --command '...'` so run-task inherits
those resources.

**Status:** required, applied. Prerequisite for getting the SDK to
load at all; unrelated to the initialize timeout.

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
Confirmed the subprocess completes its own startup in ~2–3 seconds
on CF, then waits without reading stdin or writing stdout. No
errors, no crashes. Just silence.

### 5. Tested: Python-side `logging.basicConfig(level=logging.DEBUG, force=True)`

Surfaced three Python-side log lines (asyncio selector choice, agent
sentinel, OTEL trace context failure) and nothing else. Specifically,
no `[claude_agent_sdk._internal.message_parser] DEBUG: Skipping
unknown message type` was ever emitted — meaning the SDK's
message-reader loop never sees a single byte come back from the
subprocess's stdout. **Rules out "protocol mismatch silently
swallowed."**

### 6. Tested: network reachability from inside a CF task

Ran a curl probe as a task:

- DNS for `api.anthropic.com` resolves to both IPv4
  (`160.79.104.10`) and IPv6 (`2607:6bc0::10`).
- `curl https://api.anthropic.com/` returns HTTP 404 in ~100ms (TLS
  handshake works).
- Authenticated `POST /v1/messages` with the UPS-provided
  `ANTHROPIC_API_KEY` returns HTTP 200 with a real Claude response
  in ~1.3 seconds.
- `statsigapi.net` (auxiliary telemetry host) also reachable.

**Rules out** network egress, ASG firewall, DNS, and API key
validity.

### 7. Tested: `ldd` on the bundled linux binary

All dynamic library dependencies resolved: `librt.so.1`, `libc.so.6`,
`libpthread.so.0`, `libdl.so.2`, `libm.so.6`. Nothing says "not
found."

**Rules out** missing system libraries.

### 8. Tested: `getaddrinfo` from inside a task

Python `socket.getaddrinfo("api.anthropic.com", 443, AF_UNSPEC, …)`
returns both IPv4 and IPv6 addresses. `/etc/nsswitch.conf` has
`hosts: files dns`. `/etc/gai.conf` is empty (glibc defaults).

Earlier `getent hosts` had only returned IPv6 which was a red
herring. **Rules out** IPv6-only DNS as a cause.

### 9. Tested: SDK version

Latest `claude-agent-sdk` on PyPI is `0.1.63` — we're already pulling
that via `>=0.1.0`. No newer version exists. Pinning to `==0.1.63`
for reproducibility.

**Rules out** stale version.

### 10. Tested: Python 3.14 vs 3.10 locally

Ran the same test locally on Mac with both Python 3.10 (default) and
Python 3.14 (same as CF's `python_buildpack` picks). Both succeed
with clean `SystemMessage(init)` → `AssistantMessage` →
`ResultMessage` returns in <5s.

**Rules out** Python 3.14 specifically.

### 11. Tested: `uv run` stdio wrapping

Hypothesis: CF captures the task's stdin/stdout for Loggregator, and
`uv run`'s stdio handling may propagate that somehow into the
subprocess pipes.

Test: bypass `uv run` — invoke the venv's Python binary directly:
`cf run-task --process task --command
'/home/vcap/deps/1/uv_venv/bin/python agent.py "say hello"'`.

**Result:** same timeout. **Rules out** `uv run`'s stdio handling.

### 12. Tested: standalone-downloaded binary instead of the SDK-wheel-bundled one

Both are Claude Code 2.1.114 but come from different build pipelines
(`downloads.claude.ai` vs the Python wheel). Swapped `cli_path` to
`./bin/claude` (the scenario-1 downloaded binary copied into scenario
2's droplet).

**Result:** same timeout. **Rules out** the SDK-wheel packaging
being different from the direct-download build.

### 13. Tested: Docker `cloudfoundry/cflinuxfs4:latest` as `vcap`

Built a local Docker image using `cloudfoundry/cflinuxfs4:latest` as
the base, installed uv + the SDK, and ran as the `vcap` user
(`USER vcap`, uid 2000 — the same uid CF uses). Used
`--platform=linux/amd64` on Apple Silicon so Rosetta emulates the
linux-x64 binary architecture.

**Result:** ✅ **works**. Got `AssistantMessage(content=[TextBlock(
text="Hello! Hope you're having a wonderful day! 👋")])` and a
successful `ResultMessage` in 2.9 seconds.

**Same rootfs image, same user, same binary, same Python, same
code — works in Docker, hangs on CF.** At this point the suspect
list collapsed to "something about CF's task runtime itself" and the
investigation looked stuck.

### 14. Tested: TypeScript SDK on CF — scenario 4

Built `04-claude-ts-agent/` as a direct mirror of scenario 3:
- Same UPS-delivered credentials.
- Same target repo (`asaikali/spring-petclinic`).
- Same `apt.yml` (`gh`, `ripgrep`, `temurin-25-jdk`).
- Same `.profile.d/` shims.
- Same prompt text, same tool allowlist, same `settingSources: []` +
  `permissionMode: "bypassPermissions"`.
- Only the SDK (`@anthropic-ai/claude-agent-sdk`) and release
  buildpack (`nodejs_buildpack`) differ.

**Result:** ✅ **the SDK works on CF.** The smoke task reaches
`SUCCEEDED`. The agent completes its `initialize` in under two
seconds, streams real `AssistantMessage` tool-use rounds (one of
which successfully `gh repo clone`s Spring PetClinic), gets real
tool results back, and returns a proper `ResultMessage`. No init
timeout.

(The scenario 4 smoke *fails* at the subsequent `./mvnw compile -q`
step with a Maven SSL trust-store error:
`java.security.InvalidAlgorithmParameterException: the trustAnchors
parameter must be non-empty`. That's a separate, unrelated
environmental problem: Tanzu's Temurin package from `apt-buildpack`
isn't wired up to a CA trust store. Easy env-var / package fix, and
irrelevant to the SDK investigation.)

This data point is what isolated the bug to the Python SDK
specifically. Before scenario 4 we thought the CF runtime was
fundamentally incompatible with Claude Code's streaming mode. After
it, we know the CF runtime is fine — only the Python SDK's native
subprocess code path is affected.

## Ruled out

Based on the above, all of the following are confirmed **not** the
cause:

- Anthropic Claude Agent SDK protocol design itself (TS SDK works on CF)
- `ClaudeAgentOptions` content
- Python 3.14 compatibility
- `uv run` / `uv`'s subprocess handling
- The SDK-bundled vs standalone download of the linux binary
- Missing library dependencies on the bundled binary
- Network egress / ASG firewall / DNS / IPv6 resolution quirks
- cflinuxfs4 rootfs itself
- The `vcap` user identity
- `permission_mode="bypassPermissions"` being rejected
- The API key
- The CF runtime being incompatible with Claude Code in general

## Remaining suspects (Python SDK on CF specifically)

Variables that still differ between the successful
Docker-cflinuxfs4-vcap run and the failing CF-cflinuxfs4-vcap run,
narrowed to things that affect the Python SDK's **subprocess stdio
pipe handshake**:

1. **Environment variables.** CF injects a bunch of runtime env vars
   (`VCAP_SERVICES`, `VCAP_APPLICATION`, `PORT`, `CF_INSTANCE_*`,
   `MEMORY_LIMIT`, etc.) that Docker doesn't. One or more of these
   might be read by the bundled Bun CLI and change its init behavior.
2. **Container runtime differences.** CF uses Garden (runc under the
   hood with Diego-specific cgroup and namespace configs). Docker
   Desktop uses its own runtime. Differences in:
   - seccomp / AppArmor profile
   - cgroup v1 vs v2 pipe size limits
   - Pipe buffer sizes (kernel param `pipe-max-size`)
   - PID namespace behavior
   - signal / process-reaper behavior (Diego uses a specific init
     process)
3. **Specific ordering inside the CLI startup.** On successful runs
   the CLI emits `Stream started - received first chunk` (an inbound
   API streaming response) *before* `[mcp-registry] Loaded 197
   official MCP URLs (legacy)`. On failing CF runs the MCP-registry
   line is the last thing emitted before the hang. Something may be
   racing that doesn't race when the CLI is in-process.
4. **Filesystem mount types.** CF's task container mounts its
   writable layer with specific options Docker doesn't use. If the
   Bun binary does something that behaves differently on those mount
   types (memory-mapped temp files, `F_GETFL` on a pipe, etc.), this
   could manifest as a hang.

None of these explain why only the **native-subprocess** code path
is affected. The TS SDK running `cli.js` in-process reads from stdin
differently — via Node's EventEmitter on `process.stdin` rather than
via anyio/asyncio reading from a child subprocess's stdout pipe. So
the bug is specifically in the stdio pipe relationship **between a
Python parent and a native Bun-binary child** under CF's runtime.

## Workarounds

### Use the TypeScript SDK (scenario 4)

See `04-claude-ts-agent/`. Same agent shape as scenario 3, different
language. Works today.

### Shell out to `claude -p "<prompt>"` from Python via `subprocess.run`

Explicitly not done in scenarios 2/3 because it gives up the SDK's
typed message stream and hook surface. But mentioned here because the
`-p` batch mode works on CF — scenario 1 proves it. If you really
need Python and can live without streaming-mode features, this is
feasible.

## Concrete next steps if someone wants to fix the Python-SDK case

In rough order of cost / signal:

1. **Env-var diff.** Capture `env` output in both a CF task and a
   local Docker cflinuxfs4 container. Diff. Identify CF-only vars.
   Inject them one by one into the Docker run via `-e`. When one
   reproduces the hang, we have the smoking-gun trigger.

2. **File an upstream bug at `anthropics/claude-agent-sdk-python`**
   with the repro. The new TS-works / Python-hangs comparison makes
   this a high-quality report: "the bundled Bun CLI's streaming init
   stalls when spawned as a subprocess under Diego/runc but not when
   run in-process via the TS SDK, not when run under runc standalone
   (Docker), not when run on macOS."

3. **Run the SDK under `strace -e trace=read,write,close -p <pid>`**
   on the CF side if we can get `strace` installed via `apt.yml` and
   CF task permissions allow it. Would show whether the subprocess
   is reading stdin and/or writing stdout during the silence.

4. **Instrument the SDK itself** (monkey-patch
   `subprocess_cli.py`'s stdin-write and stdout-read paths) to log
   every byte. Would tell us whether the Python side is actually
   writing the initialize JSON to the subprocess and whether the
   subprocess is writing anything back.

## Files of interest

### Scenario 3 (broken Python SDK state, preserved)

- `03-claude-issue-agent/agent/agent.py` — production entrypoint with
  the full CI/headless options set.
- `03-claude-issue-agent/agent/smoke_test.py` — verification prompt,
  same options.
- `03-claude-issue-agent/agent/debug_sdk.py` and
  `03-claude-issue-agent/agent/raw_probe.py` — diagnostic scripts
  from the investigation.
- `03-claude-issue-agent/manifest.yaml` — task process has
  `memory: 2G` and `disk_quota: 8G`.
- `03-claude-issue-agent/verify.sh` — runs `smoke_test.py` via
  `cf run-task --process task`.

### Scenario 4 (working TypeScript SDK)

- `04-claude-ts-agent/agent/agent.ts` — production entrypoint,
  TypeScript translation of scenario 3's `agent.py`.
- `04-claude-ts-agent/agent/smoke_test.ts` — verification prompt,
  TypeScript translation of scenario 3's `smoke_test.py`.
- `04-claude-ts-agent/agent/package.json` — pins
  `@anthropic-ai/claude-agent-sdk` and `tsx`.
- `04-claude-ts-agent/manifest.yaml` —
  `apt-buildpack` + `nodejs_buildpack` chain.
- `04-claude-ts-agent/verify.sh` — runs `smoke_test.ts` via
  `cf run-task --process task`.

### Local harness (not in this repo)

- `/tmp/claude-501/claude-sdk-local/` — Dockerfile that reproduces
  the successful Python-SDK case under a local Docker cflinuxfs4
  container. Useful as the control point for any future CF-specific
  investigation.
