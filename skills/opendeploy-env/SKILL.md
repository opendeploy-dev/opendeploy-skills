---
name: opendeploy-env
version: "0.0.20"
description: Scan, upload, patch, unset, rotate, or reconcile OpenDeploy environment variables and secrets. Use when the user says .env upload, env vars, environment variables, config vars, secrets, import env, sync env, env diff, set env, unset env, remove env key, rotate secret, AI Hub key, AI provider key, OpenAI key, Anthropic key, Gemini key, DATABASE_URL, REDIS_URL, MONGODB_URI, or asks to sync env into a service.
user-invokable: true
---

# OpenDeploy Env

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

Show key names only. Never print values.
CLI env output may preserve variable names while redacting every value; this is
display-layer redaction, not proof that a non-sensitive value was encrypted or
changed. Treat backend/dashboard `is_encrypted` as the storage signal, and keep
agent transcripts key-only unless the user explicitly asks to reveal values.

`.env.example`, `.env.sample`, and `.env.template` are schema/default hints
only. They can identify missing keys, including public build-time keys such as
`VITE_*`, but their values are not deploy values and must not be uploaded as
runtime or build env. Ask the user for real values, or confirm the app can build
without them.

When an app reads required env keys, first resolve the env source. Do not jump
straight to deploy with empty required values.

Keep runtime and build env separate. Runtime env is read by the running
container; build env is read by Dockerfile `ARG`, build scripts, or public
client compile-time prefixes (`NEXT_PUBLIC_`, `VITE_`, `REACT_APP_`,
`PUBLIC_`, `NUXT_PUBLIC_`, `EXPO_PUBLIC_`). Do not patch/import the same full
keyset into both Runtime Variables and Build Time Variables. A key may be in
both only when source evidence shows both phases consume it.

Use a structured question:

- If a real local `.env` exists: `Sync my .env file (Recommended)`,
  `Set required vars manually`, `Continue without optional vars`.
- If no real `.env` exists: `Set required vars manually (Recommended)`,
  `I'll add a .env file`, `Continue without optional vars`.

Only show key names. Never show values. Do not present `Continue without
optional vars` for keys that source evidence marks required.

For external storage, OAuth, payment, or other user-owned secret sets, get the
values through structured secret input when available, or ask for a local 0600
env/body file path. The agent should run the OpenDeploy env patch/import
commands itself. Do not make the user copy a block of CLI commands as the normal
path, and do not paste placeholder secret values into transcripts.

AI provider keys are special. **During a first deploy run by the `opendeploy`
autoplan, do not handle AI keys in this skill** — the autoplan's Step 6.25 +
Step 9.5 already do the explicit `ai-hub keys provision` + local `.env` fill
end-to-end. Defer to that flow.

For env operations OUTSIDE a first deploy (e.g. adding an AI provider key
to an existing service, rotating, or patching env on a redeploy that did
not re-run Step 9.5), offer OpenDeploy AI Hub before asking the user for
provider key values. When the user chooses OpenDeploy AI Hub, hand off to
the `opendeploy-ai-hub` skill — it runs `ai-hub keys provision` explicitly,
optionally writes local `.env`, and patches the service env with the
`{{OPENDEPLOY_AI_API_KEY}}` placeholder (canonical backend placeholder
string — keep the literal value as-is, paired with base URL
`https://api.opendeploy.dev/v1`). Do not place this placeholder in
`build_variables`. If the AI Hub key is required during build, ask for
user-provided build-time values or patch the build to avoid provider calls
during build.

```bash

# Read
opendeploy env scan . --json                                                   # local files, key names only
opendeploy services env get <project-id> <service-id> --json                   # current service env, redacted
opendeploy services env export <project-id> <service-id> --json                # full export, redacted by default

# Mutate (each preserves keys not named in the call)
opendeploy services env patch <project-id> <service-id> --set KEY=value --confirm-env-upload --json
opendeploy services env unset <project-id> <service-id> KEY --confirm-env-upload --json
opendeploy services env reconcile <project-id> <service-id> --from-plan .opendeploy/plan.json --json

# Full replace (drops omitted keys — show key-only diff and confirm first)
opendeploy services env set <project-id> <service-id> --confirm-env-upload --json
opendeploy services env import <project-id> <service-id> --file .env --confirm-env-upload --json
```

Rule of thumb: prefer `patch` / `unset` / `reconcile` over `set` / `import`.
The latter two replace the entire keyset, so any key not in the input is
removed.

Env mutation does not hot-reload a running container. After `patch`, `unset`,
`set`, `import`, or `reconcile`, read back key names and tell the user the
service needs a new deployment before the running app reliably sees the new
values. Current OpenDeploy restarts have been observed to keep the old pod env
even when the service record is patched, so the recommended option label should
be `Patch env + redeploy (Recommended)` for app-visible env changes, including
runtime-only keys.

```bash
opendeploy deployments create --project <project-id> --service <service-id> --json
```

If the changed key is a build-time key (`VITE_*`, `NEXT_PUBLIC_*`,
`PUBLIC_*`, framework compile-time config, or anything used by the build
script), redeploy is mandatory. Use `services restart` only for non-env
live-service actions or when a current CLI/backend response explicitly proves
the restart will refresh pod env.

## Workflow when full replace is needed

1. Read current keys with `services env get` (key names only).
2. Build the desired keyset locally.
3. Show the user a key-only diff: `+ADDED`, `-REMOVED`, `~CHANGED`.
4. Ask for confirmation. Default no.
5. Run `services env set` (or `import` for `.env` file) only after approval.
6. Re-read the service and verify the key names match.
7. Ask for `Patch env + redeploy (Recommended)` for app-visible env. Restart
   only when the current backend explicitly guarantees env refresh on restart.

## Rules

- Env key deletion is allowed when explicitly requested.
- Warn before deleting DB-generated keys such as `DATABASE_URL`, `REDIS_URL`,
  `MONGODB_URI`, `MYSQL_URL`, or `POSTGRES_URL` — removing them breaks the
  consuming service.
- Empty user values must not override managed DB env.
- Placeholder values (`change-me`, `your-key-here`, `xxx`) must not override
  managed DB env.
- After mutation, read back key names and verify.
- For OpenDeploy AI Hub managed keys, verify key names only. The stored value
  will be encrypted/resolved server-side; do not reveal or compare token values.
- After mutation, surface the CLI `restart_required` / `restart_command` if
  present as advisory only. Prefer a new deployment for env visibility until
  the backend proves restart refreshes pod env. Do not silently restart or
  redeploy a live service.
- Never log, echo, or pass env values to non-OpenDeploy hosts.
