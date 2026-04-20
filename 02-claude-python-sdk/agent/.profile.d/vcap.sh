# Bridge from CF's VCAP_SERVICES JSON to the flat env vars the tools expect.
#
# The Claude Agent SDK reads ANTHROPIC_API_KEY, and gh reads GH_TOKEN. CF
# drops both secrets inside the VCAP_SERVICES JSON blob when the app binds
# the anthropic-creds and github-creds user-provided services, so this script
# pulls them out with jq and re-exports them under the names the tools
# actually read. Also runs `gh auth setup-git` so raw git clone over HTTPS
# uses the same token.
#
# CF's launcher sources every .profile.d/*.sh before every task command, so
# this runs once per task invocation in a fresh shell — no cross-task leakage.

if [ -n "${VCAP_SERVICES:-}" ]; then
  _cred() {
    echo "$VCAP_SERVICES" | jq -r --arg n "$1" --arg k "$2" \
      '."user-provided"[]? | select(.name==$n) | .credentials[$k] // empty'
  }
  _anthropic="$(_cred anthropic-creds api_key)"
  _github="$(_cred github-creds token)"
  [ -n "$_anthropic" ] && export ANTHROPIC_API_KEY="$_anthropic"
  if [ -n "$_github" ]; then
    export GH_TOKEN="$_github"
    gh auth setup-git 2>/dev/null || true
  fi
  unset _anthropic _github
  unset -f _cred
fi
