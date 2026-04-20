# 01-claude-cli

Scenario 1: run the pre-built **Claude Code CLI binary** as a `cf task`.
This is the introductory scenario in the repo — it establishes the
Cloud Foundry patterns that later scenarios reuse unchanged
(`apt-buildpack`, `.profile.d/`, user-provided services). See the
[root README](../README.md) for those shared concepts; this README
covers only what's specific to the CLI-binary payload.

## The three moving parts

1. **Download the agent binary.** `download.sh` fetches the Linux build
   of Claude Code that matches the CF stack into `./agent/bin/claude`
   so the droplet ships the exact version we intend to run.
2. **Layer on the tools the agent needs.** `apt.yml` drives
   `apt-buildpack` to install a JDK, a Node LTS, `gh`, `ripgrep`, and
   Python into the container, alongside any third-party apt
   repositories we need.
3. **Push as a task-only app.** The manifest declares no route and no
   running web process, chains `apt-buildpack` ahead of
   `binary_buildpack`, and binds the two user-provided services for
   credentials. `cf push --task` stages the droplet and leaves it
   stopped; work happens on demand via `cf run-task`.

## Layout

The scenario root holds the `manifest.yaml` and the shell scripts you
run on your laptop. Everything that `cf push` uploads lives under
`agent/` — the manifest's `path: ./agent` tells the CF CLI to upload
only that subtree. Files that need to be read *inside* the droplet
(the `apt.yml` for `apt-buildpack`, the `.profile.d/*.sh` sourced by
CF's launcher, the downloaded `bin/claude`) therefore sit inside
`agent/`; files that are read by the CF CLI on your laptop stay at the
scenario root.

## What this scenario installs via `apt.yml`, and why

The cflinuxfs4 stack already ships a lot of basics (see the
[shared-concepts section in the root README](../README.md#what-the-stack-already-ships-and-what-we-add)).
What's in `apt.yml` are the things cflinuxfs4 doesn't ship, each with a
coding-agent-specific reason:

- **`temurin-25-jdk`** — the agent may compile and run Java code, and
  we want a specific vendor and LTS rather than whatever OpenJDK point
  release Ubuntu happens to ship.
- **`nodejs`** (via NodeSource) — Vue and most modern JS tooling assume
  a current Node LTS; Ubuntu's packaged Node is several majors behind
  and not viable for the kinds of `npm`/`pnpm`/`vite` workflows the
  agent will trigger.
- **`gh`** — so the agent can read issues, open PRs, comment on
  reviews, and inspect CI runs through one well-known CLI instead of
  hand-rolling GitHub's REST API from shell.
- **`ripgrep`** — agents grep a lot, and `rg` is an order of magnitude
  faster than `grep -r` on real-world repos; the time saved across many
  invocations is material.
- **`python3` / `python3-pip` / `python3-distutils`** — ad-hoc project
  scripts in the wild routinely assume Python, and some native `npm`
  addons shell out to it during install.

### Bringing in JDK 25 (Temurin)

The Ubuntu repositories behind the CF stack ship OpenJDK 17 and 21,
not 25, and they ship Canonical's build rather than a specific vendor
distribution. To get Temurin 25 we add Adoptium's GPG key and apt repo
to `apt.yml` alongside the Temurin package name. At staging time
`apt-buildpack` trusts the key, fetches from Adoptium, and unpacks the
JDK into the droplet.

Temurin's deb installs into a versioned JVM directory and relies on
`update-alternatives` to put `java` and `javac` on `PATH` — a step
that only runs on a full Debian system, not inside an apt-buildpack
droplet. We bridge that gap with a small `.profile.d/java.sh` that
sets `JAVA_HOME` and prepends its `bin/` directory to `PATH`, so every
task invocation (including ad-hoc `cf run-task --command '...'` runs)
finds Java without ceremony.

The same pattern generalises to other JDK distributions — Corretto,
Zulu, GraalVM — or to any toolchain delivered as a third-party Debian
repo: swap the key, the repo, and the package name.

### Bringing in Node.js LTS (NodeSource)

The Node.js that ships in the Ubuntu stack is several major versions
behind the current LTS line. We pull from NodeSource, which publishes
an apt repo keyed by Node's major version. Adding its GPG key, its
repo, and the `nodejs` package to `apt.yml` is enough to land a
current Node LTS — with `npm` bundled in — into the droplet.

Unlike the JDK case, no `.profile.d/` shim is needed: NodeSource's
package installs `node` and `npm` under a directory that
`apt-buildpack` already prepends to `PATH`, so both binaries are
available to task commands out of the box. This is the contrast worth
internalising — whether a given package needs env wiring depends on
*where the deb drops its binaries*, not on the buildpack itself.

### Bringing in the GitHub CLI (`gh`)

GitHub publishes an official apt repo, so the declaration is the same
shape as the others: key, repo, and package. The deb drops `gh` onto
the default `PATH`, so no `.profile.d/` shim is needed, matching the
Node pattern rather than the JDK one.

One incidental note: GitHub's published key is a *binary* GPG key
rather than the ASCII-armored form, and `apt-buildpack` handles
either — so no extra massaging is required.
