# OpenDeploy Skills Repo Guide

This repository is the universal Agent Skills distribution for OpenDeploy.

Keep it host-neutral:

- Do not add Claude, Codex, Cursor, or OpenClaw plugin manifests here.
- Do not add host-specific hook configuration here.
- Keep plugin packaging in the dedicated plugin repositories.
- Keep `skills/` compatible with the open Agent Skills layout: each skill folder must contain a valid `SKILL.md`.

Install command used by docs:

```sh
npx -y skills add opendeploy-dev/opendeploy-skills --skill '*'
```

Global installation is recommended for most users, but let the installer present the Project vs Global choice unless docs explicitly need a non-interactive command.

Do not add `.opendeploy` to `.gitignore`; OpenDeploy project context can be intentionally shared by teams.

Before committing, run:

```sh
./scripts/validate.sh
```
