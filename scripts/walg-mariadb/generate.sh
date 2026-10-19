#!/bin/bash
#
# Writes templates/mariadb-managed.yaml from this directory: template-head.yaml,
# then each script as a config file the engine mounts at /opt/hivepaas/bin/<name>.
# Edit the scripts here, never in the template.
#
#   scripts/walg-mariadb/generate.sh          write the template
#   scripts/walg-mariadb/generate.sh -check   exit 1 when the committed template differs
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
template="$(cd "$dir/../.." && pwd)/templates/mariadb-managed.yaml"

# In the order they appear in the template. walg-lib is sourced, not run.
scripts=(walg-lib walg-run walg-archive walg-replay walg-nightly walg-health walg-mark walg-restore-test
  walg-entrypoint)

render() {
  # $(...) drops the files' trailing newlines; each block below ends its own lines.
  printf '%s\n' "$(cat "$dir/template-head.yaml")"
  printf '    configFiles:\n'
  local name mode line
  for name in "${scripts[@]}"; do
    mode=555
    [ "$name" = walg-lib ] && mode=444
    printf '      %s:\n        content: |\n' "$name"
    while IFS= read -r line; do
      if [ -n "$line" ]; then
        printf '          %s\n' "$line"
      else
        printf '\n'
      fi
    done <<<"$(cat "$dir/$name")"
    printf '        swarmRef:\n          file: {name: /opt/hivepaas/bin/%s, mode: %s}\n' "$name" "$mode"
  done
  printf '    routing:\n      port: 3306\n'
}

case "${1:-}" in
"")
  render >"$template"
  ;;
-check)
  if ! render | cmp -s - "$template"; then
    echo "templates/mariadb-managed.yaml is not what scripts/walg-mariadb makes: run scripts/walg-mariadb/generate.sh" >&2
    render | diff -u "$template" - | head -40 >&2 || true
    exit 1
  fi
  ;;
*)
  echo "usage: $0 [-check]" >&2
  exit 2
  ;;
esac
