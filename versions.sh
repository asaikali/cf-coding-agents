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
