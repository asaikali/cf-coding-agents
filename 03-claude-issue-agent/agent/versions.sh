#!/usr/bin/env bash
# Baked-in smoke test. Runs inside a cf task and prints versions of every
# tool the agent relies on, plus a credentialed git clone probe. Missing
# tools are reported as NOT FOUND rather than halting.

check() {
  local label=$1; shift
  echo "== $label =="
  "$@" 2>&1 || echo "NOT FOUND"
  echo
}

check python   python3 --version
check uv       uv --version
check java     java -version
check gh       gh --version
check git      git --version
check ripgrep  rg --version

echo "== claude-agent-sdk =="
uv run python -c 'from importlib.metadata import version; print(version("claude-agent-sdk"))' 2>&1 \
  || echo "NOT FOUND"
echo

echo "== env =="
[ -n "$ANTHROPIC_API_KEY" ] && echo "ANTHROPIC_API_KEY: set" || echo "ANTHROPIC_API_KEY: MISSING"
[ -n "$GH_TOKEN" ]          && echo "GH_TOKEN: set"          || echo "GH_TOKEN: MISSING"
[ -n "$TARGET_REPO" ]       && echo "TARGET_REPO: $TARGET_REPO" || echo "TARGET_REPO: MISSING"
echo

# Credentialed git clone probe — proves VCAP_SERVICES parsed, GH_TOKEN
# exported, and gh auth setup-git wired git's credential helper.
echo "== git clone (auth) =="
tmp_repo="$(mktemp -d)"
private_repo="$(gh repo list --visibility private --limit 1 --json nameWithOwner -q '.[0].nameWithOwner' 2>/dev/null || true)"
if [ -n "$private_repo" ]; then
  if git clone --depth 1 --quiet "https://github.com/${private_repo}.git" "$tmp_repo/probe" 2>&1; then
    echo "OK: cloned private repo ${private_repo}"
  else
    echo "FAIL: could not clone private repo ${private_repo}"
  fi
else
  if git clone --depth 1 --quiet https://github.com/octocat/Hello-World.git "$tmp_repo/probe" 2>&1; then
    echo "OK: cloned public repo (no private repo visible to this token)"
  else
    echo "FAIL: could not clone public repo"
  fi
fi
rm -rf "$tmp_repo"
