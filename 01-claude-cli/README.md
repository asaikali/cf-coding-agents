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

## How the toolbox is built with `apt-buildpack`

`apt-buildpack` is a Cloud Foundry buildpack that installs Debian/Ubuntu
packages into the droplet at staging time. We drive it with a small
declarative file listing the packages the agent needs — git, language
runtimes, anything the agent might shell out to — and the buildpack fetches
and unpacks them into the container.

Out of the box the buildpack pulls from the package repositories that back
the CF stack (cflinuxfs4 → Ubuntu Jammy). For packages that aren't in those
default repos, the same declarative file also accepts extra GPG keys and
third-party apt sources, so any vendor that publishes a Debian repository can
be pulled in the same way.

`apt-buildpack` is chained **ahead** of `binary_buildpack` in the manifest.
This matters: only the last buildpack in the chain owns the release/start
contract and decides how the app launches. `apt-buildpack`'s job ends at
"everything you declared is installed"; `binary_buildpack` remains
responsible for launching the agent. Installed files land under a well-known
dependencies directory inside the droplet. Some Debian packages put their
binaries straight on `PATH`; others expect `update-alternatives` symlinks
that are only created on a full Debian install and therefore need a little
environment wiring (see the `.profile.d/` section below).

### What the stack already ships, and what we add

Before adding anything to the apt file, check what cflinuxfs4 already
includes. The authoritative list lives in the stack's repo at
[`cloudfoundry/cflinuxfs4`](https://github.com/cloudfoundry/cflinuxfs4/blob/main/packages/cflinuxfs4).
Listing a package that's already in the base stack just inflates the droplet
and slows staging for no functional gain.

cflinuxfs4 gives us a lot of the basics for free — among them `git`, `jq`,
`unzip`/`zip`, `build-essential` (gcc, g++, make), `ca-certificates`, `curl`,
`wget`, `openssl`, and the usual diagnostic utilities. None of those appear
in our apt file.

What we *do* install via `apt-buildpack`, and why a coding agent wants each:

- **`temurin-25-jdk`** — the agent needs to compile and run Java code for
  the target project, and we want a specific vendor and LTS rather than
  whatever OpenJDK point release Ubuntu happens to ship.
- **`nodejs`** (via NodeSource) — Vue and most modern JS tooling assume a
  current Node LTS; Ubuntu's packaged Node is several majors behind and not
  viable for the kinds of `npm`/`pnpm`/`vite` workflows the agent will
  trigger.
- **`gh`** — so the agent can read issues, open PRs, comment on reviews, and
  inspect CI runs through one well-known CLI instead of hand-rolling
  GitHub's REST API from shell.
- **`ripgrep`** — agents grep a lot, and `rg` is an order of magnitude
  faster than `grep -r` on real-world repos; the time saved across many
  invocations is material.
- **`python3` / `python3-pip` / `python3-distutils`** — ad-hoc project
  scripts in the wild routinely assume Python, and some native `npm` addons
  shell out to it during install.

Anything else the agent needs should be evaluated against the same test: is
it already in the stack list linked above? If yes, skip. If no, add it
here with a short reason.

### Bringing in JDK 25 (Temurin)

The Ubuntu repositories behind the CF stack ship OpenJDK 17 and 21, not 25,
and they ship Canonical's build rather than a specific vendor distribution.
To get Temurin 25 specifically we add Adoptium's GPG key and apt repo to the
same declarative file that already lists `git`, alongside the Temurin
package name. At staging time the buildpack trusts the key, fetches from
Adoptium, and unpacks the JDK into the droplet.

Temurin's deb installs into a versioned JVM directory and relies on
`update-alternatives` to put `java` and `javac` on `PATH` — a step that only
runs on a full Debian system, not inside an apt-buildpack droplet. We bridge
that gap with a small `.profile.d/` script that sets `JAVA_HOME` and
prepends its `bin/` directory to `PATH`, so every task invocation (including
ad-hoc `cf run-task --command '...'` runs) finds Java without ceremony.

The same pattern generalises to other JDK distributions — Corretto, Zulu,
GraalVM — or to any toolchain delivered as a third-party Debian repo: swap
the key, the repo, and the package name.

### Bringing in Node.js LTS (NodeSource)

The Node.js that ships in the Ubuntu stack is several major versions behind
the current LTS line, so it's not viable for an agent that runs modern
JavaScript tooling. We pull from NodeSource, which publishes an apt repo
keyed by Node's major version. Adding its GPG key, its repo, and the
`nodejs` package alongside the existing Temurin and git entries is enough
to land a current Node LTS — with `npm` bundled in — into the droplet.

Unlike the JDK case, no `.profile.d/` shim is needed: NodeSource's package
installs `node` and `npm` under a directory that `apt-buildpack` already
prepends to `PATH`, so both binaries are available to task commands out of
the box. This is the contrast worth internalising — whether a given package
needs env wiring depends on *where the deb drops its binaries*, not on the
buildpack itself.

### Bringing in the GitHub CLI (`gh`)

A coding agent that works against GitHub — reading issues, opening PRs,
checking CI — benefits from having `gh` in the container. GitHub publishes
an official apt repo, so the declaration is the same shape as the others:
key, repo, and package. The deb drops `gh` onto the default `PATH`, so no
`.profile.d/` shim is needed, matching the Node pattern rather than the JDK
one.

One incidental note: GitHub's published key is a *binary* GPG key rather
than the ASCII-armored form, and `apt-buildpack` handles either — so no
extra massaging is required.

## Wiring environment with `.profile.d/`

Some tools installed via `apt-buildpack` need extra environment setup before
they're usable — the agent might expect `JAVA_HOME` set, or a binary located
outside the default `PATH`. Rather than bake that into every task command, we
rely on Cloud Foundry's `.profile.d/` convention.

Any `*.sh` file in a `.profile.d/` directory at the root of the pushed app is
uploaded with the droplet (CF includes dotfiles by default, respecting only
`.cfignore`) and **sourced by CF's launcher before any start command runs** —
whether that's the declared task process or an ad-hoc `cf run-task --command`.
Each invocation gets a fresh shell, so there's no cross-task leakage, and
exported variables are inherited by the agent and everything it forks.

This gives us a single, file-based place to bind buildpack-installed tools
into the container's environment, without touching the manifest, the task
command, or the buildpack itself.

## How credentials reach the agent

The agent needs two separate secrets to be useful: an **Anthropic API key**
so the model can be called, and a **GitHub token** so the agent can read
issues, open PRs, and push branches. Neither is baked into the droplet, and
neither lives in a tracked file in this repo.

### Why user-provided services instead of manifest env

The natural first approach — pass each secret as a `cf push --var` and land
it in the manifest's `env:` block — has a subtle but real leak: every value
passed to `cf push --var` is an argument on the CLI command line, so it
appears in the process's argv, in shell history, and in anything that echoes
the invoked command (like a script with `set -x`). The secret also travels
with every subsequent push.

Cloud Foundry's idiomatic answer for secrets is a **user-provided service**
(UPS). The secret is handed to CF once, outside of the push, via a separate
`cf` command that reads its JSON payload from a file path — not from an
inline CLI argument — so the secret never appears in argv or shell history.
The app binds the service by name in the manifest; inside the container the
secret appears in the `VCAP_SERVICES` JSON blob, which `cf env` redacts.
Pushes themselves carry no secret material at all.

We use **two separate services** rather than one combined blob so each
credential can rotate and be shared with other apps independently.

### The flow

1. **The secrets live on the developer's laptop.** The Anthropic key is
   expected in a shell environment variable. The GitHub token is sourced
   live from `gh`'s own secure storage (on macOS, the system Keychain) —
   whatever `gh` is logged in as locally is what the laptop carries.
2. **A small setup script publishes them into CF services.** A shell script
   reads both secrets locally and passes each one to
   `cf create-user-provided-service` (or `cf update-user-provided-service`
   when rotating) through a bash process substitution — an in-memory pipe
   that gives `cf` a file-like `/dev/fd/...` path to read the JSON from, so
   the secret lives only in memory and never hits argv or disk. Rotation
   is just re-running the script in update mode; no `cf push` needed.
3. **The manifest binds the services by name.** `cf push` itself passes no
   secret arguments; it just declares which services the app consumes.
4. **The container hoists them into env vars the tools expect.** A
   `.profile.d/` script parses `VCAP_SERVICES` at the start of every task
   invocation, exports `ANTHROPIC_API_KEY` and `GH_TOKEN`, and runs
   `gh auth setup-git` so raw `git clone`/`push` over HTTPS use the same
   token as `gh` without any extra wiring. From the agent's perspective the
   environment looks identical to the simpler env-var design; the difference
   is entirely upstream.

Because the GitHub token is fetched live from `gh`'s local storage each time
the setup script runs, rotation is essentially free: re-login with `gh` or
rotate the token in GitHub's UI, then re-run the setup script. The next task
invocation picks up the new value on its own.

The scoping of the token is inherited from whatever the laptop's `gh`
session has — fine for local experimentation. For a more production-shaped
setup, the same service contract works with a fine-grained PAT scoped to
specific repos, or with a short-lived GitHub App installation token
refreshed by an external process.
