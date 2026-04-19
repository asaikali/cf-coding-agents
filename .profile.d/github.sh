if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git 2>/dev/null || true
fi
