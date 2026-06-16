---
name: opendeploy-api
version: "0.0.20"
description: Safe OpenDeploy API escape hatch for advanced agents when the CLI lacks a route. Use only when the user says raw API, OpenDeploy API, CLI lacks route, missing CLI command, advanced API, API escape hatch, GET route, POST route, PUT route, PATCH route, or a needed OpenDeploy operation is not exposed by the CLI. DELETE remains blocked.
user-invokable: true
---

# OpenDeploy API Escape Hatch

## Invocation Preflight

If this skill is invoked directly, first run the global CLI version check unless
another OpenDeploy skill already did:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy preflight . --json
```

If global is older than npm latest, hand off to `opendeploy-setup`. If the
user skips the update, continue with the installed global CLI when it supports
the needed commands. Do not run separate `--version`, `jq`, or raw `curl`
plugin probes after this preamble.

Use only when the normal CLI command does not exist. Prefer named commands.
Run `opendeploy routes list --json` to see what the CLI already wraps before
reaching for `api`. If a named command exists but needs required flags, add the
flags or update the CLI; do not use raw API as a workaround.

```bash
opendeploy routes list --json
opendeploy routes search <keyword> --json
opendeploy api get /v1/status --json
opendeploy api post /v1/some-route --body payload.json --json
opendeploy api put /v1/some-route --body payload.json --json
opendeploy api patch /v1/some-route --body payload.json --json
```

The `--body` flag accepts a file path or `-` for stdin; `--data <json>` accepts
inline JSON. The token comes from `~/.opendeploy/auth.json` automatically and
is never sent to any host other than `dashboard.opendeploy.dev`.

## Rules

- **No `DELETE`** with an `od_*` token. For deletes, hand off to the dashboard.
- Redaction stays on by default. Env containers may show key names while every
  value is redacted; use `--show-secrets` only after explicit user request.
- Token leaves your machine only to `dashboard.opendeploy.dev`. Never echo, log, or send to any other URL.
- Ask before paid, destructive, security-sensitive, or live-service-changing requests.
- Validate the response shape before acting on it. If the route returns a structure you do not recognize, stop.
- Do not use raw API for `upload update-source`; the CLI route supports the
  required `--project-name` and `--region-id` metadata.
