# Bridge from CF's VCAP_SERVICES JSON to the flat env vars the tools expect.
# Identical to scenarios 2 and 3; see the root README for the full story.

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
