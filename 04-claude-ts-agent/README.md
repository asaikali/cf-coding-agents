# 04-claude-ts-agent

Scenario 4: mirror of scenario 3's GitHub-issue-to-PR workflow, but written
against the **TypeScript Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`)
and shipped with `nodejs_buildpack` instead of `python_buildpack`.

Exists to test whether the SDK-initialize hang documented in
[`../03-claude-issue-agent/TROUBLESHOOTING.md`](../03-claude-issue-agent/TROUBLESHOOTING.md)
is specific to the Python SDK's subprocess handling, or whether it lives in
the bundled `claude` CLI binary itself. Same binary underneath; if the bug
is in the binary's stdio under CF, this scenario hangs the same way. If the
bug is in `asyncio`-specific pipe plumbing, this scenario succeeds.

## What changes vs scenario 3

The **buildpack** and the **agent payload language** differ; everything
else is a translation:

- `manifest.yaml` chains `apt-buildpack` + `nodejs_buildpack` (scenario 3
  used `python_buildpack`).
- `agent/package.json` declares `@anthropic-ai/claude-agent-sdk` and `tsx`
  as dependencies; `engines.node >= 22` so the buildpack picks a modern
  Node.
- `agent.ts` and `smoke_test.ts` are direct ports of scenario 3's
  `agent.py` and `smoke_test.py`. Same prompt text, same tool allowlist,
  same `settingSources: []` + `permissionMode: "bypassPermissions"`
  options, same `debug-to-stderr` extra arg, same stderr callback.
- The task command runs `node_modules/.bin/tsx agent.ts` so TypeScript
  runs directly at staging; no separate compile step.
- Everything **identical to scenario 3**: `apt.yml` still installs `gh`,
  `ripgrep`, `temurin-25-jdk` (PetClinic target needs the JDK);
  `.profile.d/vcap.sh` unchanged; `.profile.d/java.sh` unchanged; both
  UPS services (`anthropic-creds`, `github-creds`) reused.

Target repo is still hard-wired via manifest env to
[`asaikali/spring-petclinic`](https://github.com/asaikali/spring-petclinic).

## Running it

If you haven't created the shared UPS secrets yet:
```sh
./create-services.sh
```
Then:
```sh
./push.sh
./verify.sh
```

Per-issue invocations match scenario 3 but run the TS entrypoint:
```sh
cf run-task agent-ts \
  --process task \
  --command 'ISSUE_NUMBER=1 node_modules/.bin/tsx agent.ts' \
  --name issue-1

cf logs agent-ts --recent
```

## Notes

- **The outcome of `verify.sh` is the actual answer we're after.** If it
  succeeds, the Python SDK is implicated and the fix is switching scenario
  3 to TS. If it hangs with a `Control request timeout`-style failure, the
  bundled `claude` binary is implicated under CF and we file upstream.
- **Node version pin.** `package.json` uses `engines.node >= 22` to get
  a reasonably recent Node LTS. If Tanzu's `nodejs_buildpack` picks
  something much newer or older than what's documented to work with the
  SDK, that'd show up as a build-time or import-time error.
- **No `package-lock.json` committed yet.** First run `npm install`
  locally to generate it, then commit.
