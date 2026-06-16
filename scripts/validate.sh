#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

node -e 'JSON.parse(require("fs").readFileSync("skills.sh.json", "utf8"))'

missing=0
for dir in skills/*; do
  [ -d "$dir" ] || continue
  if [ ! -f "$dir/SKILL.md" ]; then
    echo "Missing SKILL.md in $dir" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

if find . -path ./.git -prune -o -maxdepth 2 \( -name ".claude-plugin" -o -name ".codex-plugin" -o -name ".cursor" -o -name ".openclaw" -o -name "hooks" \) -print | grep -q .; then
  echo "Host-specific plugin packaging does not belong in this universal skills repo." >&2
  exit 1
fi

npx -y skills add . --list >/tmp/opendeploy-skills-validate.txt
grep -q "opendeploy" /tmp/opendeploy-skills-validate.txt

echo "OpenDeploy skills package validation passed."
