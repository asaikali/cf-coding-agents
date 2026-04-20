# Bridge from CF's VCAP_SERVICES JSON to the flat env vars our tools expect.
#
# When the app binds a user-provided service, CF does NOT set convenient env
# vars like ANTHROPIC_API_KEY or GH_TOKEN. Instead it drops a single env var
# named VCAP_SERVICES whose value is a JSON blob describing every bound
# service and its credentials. The Anthropic SDK and the gh CLI don't know
# how to read that blob — they only look for plain env vars.
#
# CF's launcher sources every *.sh in .profile.d/ before any start command
# (including every cf run-task invocation), so this runs in a fresh shell
# for every task, pulls the two credentials out of VCAP_SERVICES with jq,
# and re-exports them under the names the tools actually read. Also wires
# gh as git's HTTPS credential helper so raw `git clone` uses the same token.

# Guard: only do work if we're actually running inside a CF container.
if [ -n "${VCAP_SERVICES:-}" ]; then

  # Helper: pull one credential field out of one user-provided service.
  # Usage: _cred <service-name> <field-name>
  _cred() {
    echo "$VCAP_SERVICES" | jq -r --arg n "$1" --arg k "$2" \
      '."user-provided"[]? | select(.name==$n) | .credentials[$k] // empty'
  }

  # Read both secrets into shell variables (temporarily, not exported).
  _anthropic="$(_cred anthropic-creds api_key)"
  _github="$(_cred github-creds token)"

  # Only export if the field was actually present; this leaves the caller's
  # env untouched when a service is missing rather than setting an empty var.
  [ -n "$_anthropic" ] && export ANTHROPIC_API_KEY="$_anthropic"
  if [ -n "$_github" ]; then
    export GH_TOKEN="$_github"
    # Register gh as the credential helper for https://github.com/...
    # so plain `git clone`/`push` over HTTPS uses the same token as gh.
    gh auth setup-git 2>/dev/null || true
  fi

  # Clean up: don't leak intermediate shell state into the task.
  unset _anthropic _github
  unset -f _cred
fi
