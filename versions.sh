#!/usr/bin/env bash
# Print versions of every tool we expect in the droplet. Missing tools are
# reported as NOT FOUND rather than halting, so one gap doesn't hide the rest.

check() {
  local label=$1; shift
  echo "== $label =="
  "$@" 2>&1 || echo "NOT FOUND"
  echo
}

check claude    ./bin/claude --version
check git       git --version
check java      java -version
check node      node --version
check npm       npm --version
check gh        gh --version
check maven     mvn --version
check jq        jq --version
check make      make --version
check gcc       gcc --version
check ripgrep   rg --version
check python3   python3 --version
check pip3      pip3 --version

# Prove the GitHub credential flow end-to-end: clone a private repo over HTTPS
# (which forces the credential helper wired up by .profile.d/github.sh). If
# there is no private repo we can see, fall back to a public one so at least
# git/HTTPS itself is exercised.
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
