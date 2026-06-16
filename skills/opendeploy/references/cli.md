# CLI-first execution

Default execution goes through the official npm package `@opendeploydev/cli`.
Do not use direct gateway/curl snippets for the first-deploy path. If the CLI
lacks a route, use the API escape-hatch rules in the main OpenDeploy skill with
explicit user approval.

## Verify the CLI

Default runner is the global `opendeploy` command. Run global version checks
before preflight:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy update check --json
# after update prompts are handled:
opendeploy preflight . --json
```

Expected package:

- name: `@opendeploydev/cli`
- repository: `https://github.com/opendeploy-dev/opendeploy-cli`
- license: `MIT`
- security contact: `security@opendeploy.dev`

The npm commands are mandatory before deploy so stale global installs are
detected even when the installed CLI is too old to self-report updates.
`update check` includes plugin version and CLI update status. `preflight`
includes auth state, saved context, gateway health, and a read-only plan
summary. If package or plugin metadata cannot be verified, do read-only
inspection only. Ask the user before any mutating deploy step.

## Agent plugin updates

When `opendeploy update check --json` or `opendeploy preflight . --json`
reports a stale OpenDeploy skill/plugin, inspect `plugin.installed_plugins[]`
and `plugin.update_available_platforms[]` before acting. A machine can have
Claude, Codex, Cursor, OpenClaw, and OpenCode installed at different versions; a
current plugin on one host does not prove the other host plugins/skills are
current. Ask the plugin update question before deploy mutation when the current
host is stale or the current host cannot be determined. Use the command for the
stale host:

```bash
# Claude Code
claude plugin marketplace update opendeploy
claude plugin update opendeploy@opendeploy

# Codex
codex plugin marketplace upgrade opendeploy

# Cursor
# Use Cursor plugin UI, or run this in Cursor Agent chat:
/add-plugin https://github.com/opendeploy-dev/opendeploy-cursor-plugin

# OpenClaw
openclaw plugins update opendeploydev
# If updating by the recorded ClawHub package spec:
openclaw plugins update clawhub:opendeploydev

# OpenCode
curl -fsSL https://raw.githubusercontent.com/opendeploy-dev/opendeploy-opencode/main/install.sh | bash
```

For OpenClaw, the source of truth is the tracked plugin install record. The
OpenDeploy plugin id is `opendeploydev`, and ClawHub installs record the spec
`clawhub:opendeploydev`. `openclaw plugins update <id-or-npm-spec>` follows
that record and fetches the newer ClawHub package. Do not use
`openclaw skills update` for this package-level update; that command is for
standalone workspace skills. After the update command finishes, run `openclaw gateway restart`; the CLI
prints `Restart the gateway to load plugins and hooks`. If the package version
is unchanged, OpenClaw may also print `opendeploydev already at the current version`; treat
that as a version-status line, not a deploy blocker. If the running OpenClaw
agent still does not see the new skill text after gateway restart, start a new
agent session.

For OpenCode, OpenDeploy is distributed as native skills and slash commands,
not as a marketplace plugin. The install script is intentionally idempotent:
running it again updates `~/.agents/skills/*`, `~/.config/opencode/commands/*`,
and the local OpenDeploy skill version marker. If the running OpenCode session
still sees old skill text after the update, start a new session.

Before preflight-driven deploy planning or any deploy mutation, check the
global CLI with `npm list -g @opendeploydev/cli --depth=0 --json` and
`npm view @opendeploydev/cli version --json`. If `npm list -g` exits nonzero
because the package is not installed, treat that as a normal first-run
`cli_missing` state: ask once to install the official global CLI and continue.
If npm latest is newer than the installed global CLI, offer to update. If the
user declines, continue with the installed global CLI when it supports the
needed commands:

```bash
# Optional update — only @opendeploydev/cli, never npm itself:
npm install -g @opendeploydev/cli@latest
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy update check --json
opendeploy preflight . --json
```

## Command runner

Use `opendeploy <args>` for the entire workflow. Do not use `npx` for preflight
or as an auth/deploy fallback. If global is missing or stale, install/update it
with `npm install -g @opendeploydev/cli@latest` after one setup approval; if the
user declines and the installed global CLI cannot run the required command,
stop before mutation instead of using `npx @opendeploydev/cli`.

Do not define a shell function alias like `od() { … }; od …` — the auto-approve
hook rejects shell composition (`;`, `|`, `&&`), so the wrapper plus an
invocation collapses to a permission prompt.

Always request JSON for machine parsing:

```bash
opendeploy <resource> <action> ... --json
```

Do not use `--show-secrets` unless the user explicitly asks to reveal secret
values. CLI env containers preserve key names and redact every value by
default. This is a display-layer safety guard, not a storage/encryption claim.
If a command returns decrypted env values, keep them in memory or a mode-0600
scratch file and never print them.

## Auth

Check existing auth:

```bash
opendeploy auth status --json
```

If there is no `OPENDEPLOY_TOKEN`, profile key, or auth file key, surface
the credential consent prompt from `SKILL.md`. Only after approval:

```bash
opendeploy auth guest --name "$AGENT_DISPLAY_NAME" --json
```

This writes `~/.opendeploy/auth.json` with mode `0600`. For CI/headless
contexts, do not create a local deploy credential; require `OPENDEPLOY_TOKEN` or a
pre-provisioned auth file.

`AGENT_DISPLAY_NAME` is chosen by the agent and is only a bind-page/settings
label. It is not used by the backend to match or verify auth.

## First deploy sequence

Normal first deploy is no-pay and no-account: after local deploy credential
consent, OpenDeploy deploys and returns a bind-first project claim link for
unbound guest projects, or a live URL plus dashboard URL for account-bound
projects. For unbound guest projects, the final user-facing answer prints only
the bind link — not the live URL — because the dashboard shows the live app after
binding. Do not ask for payment, plan choice, account creation, staging, or
region preference unless the CLI/gateway returns a concrete gate.

Start with the global CLI preflight:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy update check --json
opendeploy preflight . --json
```

If `update check` reports `updates.plugin_update_available`, use
`opendeploy-setup`, name the stale platform(s) from
`plugin.update_available_platforms[]`, and recommend `Update plugin now` before
the next step when the current host is stale or unknown. If only other installed
agent surfaces are stale, mention their update commands as housekeeping and
continue the current deploy. If the user skips the plugin update, continue with
the loaded plugin and record the skip. Then, if npm latest is newer than global or `update check` reports
`cli.update_required_for_deploy` / `updates.cli_update_available`, use the same
setup flow for the CLI question before project-specific analysis and make
`Update global CLI and continue (Recommended)` the first option. Do not
recommend skipping merely because the current command family appears compatible.
If the user updates the CLI, rerun `update check` and preflight. If the user
skips the CLI update, continue with the installed global CLI if it supports this
workflow. If preflight reports plan issues, fix the plan before creating cloud
resources.

Progress-aware build watching and service create read-back require CLI `0.1.12+`.
Smart source archives, deployment-auditor plan output, dependency credential
fields, bound credential status, and post-deploy context save require CLI
`0.1.19+`:

```bash
opendeploy deploy wait "$DEPLOYMENT_ID" --follow --json
opendeploy deploy progress "$DEPLOYMENT_ID" --json
```

Both return `progress_percent`; `deploy wait --follow --json` emits JSONL
`deployment_progress` events until a terminal event. User-facing updates during
long builds must include the percent, not just "still building".

The current `opendeploy deploy <path> --project <id> --service <id>` shortcut
is for redeploying an existing service. For a cold first deploy, orchestrate
with resource commands:

1. Analyze locally with `references/analyze-local.md`.
2. Pick the active OpenDeploy default region:

```bash
opendeploy regions list --json
```

For normal first deploy, do not ask the user for a region. The normal
user-facing region is `us-east-1`; use the API default or the only healthy
active region. Ask only if the user explicitly requests a region or the API
returns multiple user-facing active regions with no default.
Use the returned region `id` in commands. Do not repeat the raw API `name` in
user-facing prose; if a legacy response says `east-us-1`, display `US East 1`
or `us-east-1`. Do not print the region UUID/internal DB id in user-facing
updates.

3. Create the project:

```bash
opendeploy projects create \
  --name "$PROJECT_NAME" \
  --repo "${GIT_URL:-file://upload}" \
  --branch "${GIT_BRANCH:-main}" \
  --region "$REGION_ID" \
  --skip-validation true \
  --json
```

If this command returns a 5xx, times out, or exits after a long request, read
back projects by stable name before retrying. Do not try several alternate
create payload shapes; one ambiguous create can already have committed. Continue
only after exactly one project id is resolved.

4. Create managed dependencies before app services, one per detected engine.
   Do not rely on backend default credentials. Either generate strong
   credentials locally or wait for user-provided credentials, then send them in
   a `0600` body file:

```bash
umask 077
mkdir -p .opendeploy
opendeploy dependencies create --body .opendeploy/dependency.json --json
```

The body should include `project_id`, `dependency_id`, `username`, `password`,
and, for SQL/MongoDB, `database_name`. For generated credentials, use a
username such as `app_<8 random hex chars>` and a password that satisfies the
app's documented constraints. If the app has no constraint, use a 32+ char
CSPRNG password. If the app requires exactly 16 chars or a max length, generate
that length with a safe charset such as `A-Za-z0-9_-`. Never use `admin` /
`changeme`, and never put passwords in argv.

Then poll until the dependency is ready and collect returned `env_vars`:

```bash
opendeploy dependencies wait "$PROJECT_ID" --json
opendeploy dependencies status "$PROJECT_ID" --json
```

Prefer the CLI wait command over custom background scripts. If the host agent
uses a monitor, the monitor must treat `pending` / `deploying` / unchanged state
as normal waiting and exit `0` for those polls. Do not let `jq -e`, `grep`, or a
status-change predicate turn "not ready yet" into exit code `1`. Only terminal
`failed` should fail the monitor. After any monitor failure, run
`dependencies status` once before reporting failure; if the dependency is
`running`, continue.

If `dependencies env/status` reports `placeholder_secret_keys`, compare those
keys to the service env contract. Stop before service creation only when a key
the app will consume, a generated connection URL, or a synthesized consumed
alias would receive a placeholder value such as `changeme`, `password`, or
`secret`. If the placeholders are unused compatibility aliases while the app's
canonical key such as `DATABASE_URL` is real, continue with a key-only warning.

**Canonical / alias divergence check.** Do not assume the canonical key is the
trustworthy one. Before service creation, fetch `dependencies status --json` and
compare `connection_info.username` and `connection_info.database` against the
user and database parsed out of `DATABASE_URL` / `MONGODB_URI`. If they
disagree, the canonical URL was synthesized by the backend with placeholder
parts (e.g. user `app_user`, db `<project_name>`) and will fail authentication
at runtime. Either patch the canonical `DATABASE_*` / `MONGODB_*` keys via
`services env patch` using values from the alias group (`POSTGRES_USER`,
`PGDATABASE`, `MONGO_USER`, etc.), or plan a Dockerfile `CMD` / `start_command`
that constructs the URL inside the container at startup from the alias env.

For an existing running dependency whose credential needs to change:

```bash
opendeploy dependencies update-connection "$PROJECT_ID" "$PROJECT_DEPENDENCY_ID" \
  --body .opendeploy/db-credentials.json \
  --json
```

Then run `opendeploy dependencies wait/env`, patch or reconcile the updated
dependency env into every consuming service runtime env, and create new
deployments for those services. The dependency credential update changes the
database/cache and its stored env; already-running app services do not see the
new password until their pod env is refreshed by a new deployment.

Use this rotation path for Postgres/MySQL/MongoDB. For Redis, prefer creating
the dependency with explicit credentials up front and then using the exact
returned `REDIS_URL` / `REDIS_*` values. Do not use Redis
`update-connection` to recover a first-deploy auth failure; if Redis runtime
logs report `invalid username-password pair` or `user is disabled` after a
rotation, stop and ask for dependency recreation or OpenDeploy support.

For temporary external DB/cache inspection without redeploying the app:

```bash
opendeploy dependencies port-access enable "$PROJECT_ID" "$PROJECT_DEPENDENCY_ID" \
  --confirm-security-sensitive --json
opendeploy dependencies port-access status "$PROJECT_ID" "$PROJECT_DEPENDENCY_ID" --json

# Run the smallest read-only local client query needed, keeping credentials in
# 0600 temp files and out of argv/chat.

opendeploy dependencies port-access disable "$PROJECT_ID" "$PROJECT_DEPENDENCY_ID" --json
```

On older CLIs, use the same backend routes through `opendeploy api post|get`:

```bash
opendeploy api post "/projects/$PROJECT_ID/dependencies/$PROJECT_DEPENDENCY_ID/port-access/enable" \
  --confirm-security-sensitive --json
opendeploy api get "/projects/$PROJECT_ID/dependencies/$PROJECT_DEPENDENCY_ID/port-access" --json
opendeploy api post "/projects/$PROJECT_ID/dependencies/$PROJECT_DEPENDENCY_ID/port-access/disable" --json
```

The enable route is security-sensitive because it opens a managed dependency on
an external TCP port. Always disable it after the query. Prefer this path over
adding a temporary app debug endpoint, because it requires no source edit and no
redeploy.

5. Merge dependency env vars plus approved user `.env` values into the service
body. Keep real values out of stdout. Use the smallest schema-valid body for
initial service creation; if the exact create schema is uncertain, create with
stable core fields first, read back verification, then patch env/config with
the dedicated commands. Do not keep retrying complex bodies that add
unsupported fields, and never create duplicates while probing schema shape.

```bash
opendeploy services create "$PROJECT_ID" --body service.json --json
```

`services create` performs a read-back verification. It may patch a dropped
`port`, `port_locked`, or `start_command` once, then returns `verification.ok`.
Do not upload source or create a deployment unless `verification.ok` is true.
Before creating, list/read existing services for the project and reuse or patch
a matching service name. If create returns 5xx or times out, read back by stable
service name before retrying; do not create duplicate services while searching
for a schema that works.

`service.json` must set:

- `name`
- `type` (`web` for an HTTP service, `worker` for a background service,
  `cron` for scheduled work, `static` only for static-site service mode)
- `language`
- `framework`
- `port`
- `start_command`
- `build_command`
- `runtime_variables`
- `build_variables`
- resource caps appropriate for the credential

The env field names are exact. Use only `runtime_variables` and
`build_variables`; never `runtime_env`, `runtime_envs`, `env`,
`environment_variables`, `runtimeVars`, `build_env`, or `buildtime_variables`.
Those aliases may be ignored by the backend and leave the service with empty
env. These exact fields are separate maps, not aliases for the same map:
runtime values are injected into the running container, while build values are
available to build commands / Dockerfile `ARG` / client compile-time public
prefixes. Do not copy all runtime keys into `build_variables` or all build keys
into `runtime_variables`. Before create, run a local JSON check or equivalent
and verify the planned key names are under the exact fields with any overlap
explained by source evidence.

Minimum pre-create body validation:

```bash
jq -e '.type as $t | ($t == "web" or $t == "worker" or $t == "cron" or $t == "static")' service.json
jq -e 'has("runtime_env") or has("runtime_envs") or has("env") or has("environment_variables") or has("runtimeVars") or has("build_env") or has("buildtime_variables") | not' service.json
```

If the API returns `CreateServiceRequest.Type` or `Type required`, the body is
schema-invalid. Add the correct `type` to the same body, read back services by
stable name, and retry once only if no matching service was created.

Immediately after service creation, read back key names:

```bash
opendeploy services env get "$PROJECT_ID" "$SERVICE_ID" --json
```

If env was expected but the read-back is empty or missing required keys, stop
before upload/deployment and patch with a 0600 body file via
`opendeploy services env patch ... --body ... --confirm-env-upload --json`.

6. Upload and bind source:

```bash
opendeploy archive create "$SOURCE_PATH" --json
UPLOAD_RESULT="$(opendeploy upload update-source "$PROJECT_ID" "$SOURCE_PATH" \
  --project-name "$PROJECT_NAME" \
  --region-id "$REGION_ID" \
  --json)"
BOUND_SOURCE_PATH="$(printf '%s' "$UPLOAD_RESULT" | jq -r '.source_path // empty')"
TEMP_FILE_PATH="$(printf '%s' "$UPLOAD_RESULT" | jq -r '.upload.temp_file_path // empty')"
PACKAGE_FILE="$(basename "$(printf '%s' "$UPLOAD_RESULT" | jq -r '.upload.temp_file_path // empty')")"
```

CLI `0.1.19+` returns `included_overrides`, `required_files`,
`secret_like_entries`, `git_metadata`, and `warnings` from `archive create` /
deploy-plan archive manifest. Trust this as the primary archive manifest. It
should keep project-owned `build/` source directories and credential-free
`.npmrc`, while excluding `.npmrc` files that contain auth material. It should
also flag `.git` bind mounts and Git metadata scripts before upload. Do not
hand-roll a ZIP unless this command fails or the manifest proves a required
non-secret file is still missing.

This command performs upload-only and update-source. It is required before
deployment creation. Do not rely on upload-only for deploys. If the gateway
complains that `project_name` or `region_id` is missing, rerun this command with
the flags above or update the CLI; do not switch to raw API for this known path.
If the upload returns 504, first read back the project and source state; the
backend may have completed the bind after the edge timed out. Retry only when
`source_path` is empty, `original_file_size` is zero, or the project source
does not match the archive you intended to send.

7. Create deployment:

```bash
opendeploy deployments create \
  --project "$PROJECT_ID" \
  --service "$SERVICE_ID" \
  --version-type "${VERSION_TYPE:-patch}" \
  --description "$DEPLOYMENT_DESCRIPTION" \
  --source "$SOURCE_KIND" \
  --file-name "$PACKAGE_FILE" \
  --source-path "$BOUND_SOURCE_PATH" \
  --temp-file-path "$TEMP_FILE_PATH" \
  --json
```

For agent-created deployments, do not leave history metadata blank. Use
`source=upload` for local source packages, `source=git` for repository deploys,
and pass the package file plus the upload-bound `source_path` when known.
Backend `0.1.19+` also snapshots `runtime_variables` and `build_variables`
onto the deployment row at creation time so deployment history can show the
env set used by that version. If the agent just wrote env in the same flow,
pass explicit `runtime_variables` / `build_variables` through a 0600
deployment body file rather than relying only on flags. Keep the split intact
when building that body; do not reuse one env object for both fields.

8. Watch until terminal:

```bash
opendeploy deployments get "$DEPLOYMENT_ID" --json
opendeploy deployments logs "$DEPLOYMENT_ID" --query tail=300
```

Use build logs for build-phase failures:

```bash
opendeploy deployments build-logs "$DEPLOYMENT_ID" --follow
```

9. Resolve domain after deployment is active:

```bash
opendeploy domains list --service "$SERVICE_ID" --type auto --json
opendeploy domains check-subdomain "$SUBDOMAIN" --json
opendeploy domains update-subdomain "$DOMAIN_ID" --subdomain "$SUBDOMAIN" --json
```

Only print the account-binding URL after a deployment has an active app URL in
the report. For unbound guest projects, print the bind-first Branch A handoff
instead of separately printing the live URL.
Prefer:

```bash
opendeploy deploy report "$DEPLOYMENT_ID" --json
```

## Monitoring and logs

Read-only inspection:

```bash
opendeploy status --json
opendeploy monitoring project-health "$PROJECT_ID" --json
opendeploy monitoring project-metrics "$PROJECT_ID" --kind batch --json
opendeploy monitoring dependency-health "$PROJECT_ID" --json
opendeploy monitoring dependency-metrics "$PROJECT_ID" --json
opendeploy services health "$SERVICE_ID" --json
opendeploy services logs "$PROJECT_ID" "$SERVICE_ID" --query tail=300
opendeploy deployments logs "$DEPLOYMENT_ID" --query tail=300
```

If `status --json` reports `gateway: ok` but a downstream circuit breaker is
`open`, the CLI is installed and reachable; avoid mutating calls that depend on
that downstream service until it recovers.

## Known CLI gotchas (workarounds)

These are CLI/backend behaviors observed in real deploys. Until upstream fixes
land, work around them rather than retrying:

- **`opendeploy dependencies env --show-secrets` ignores the flag** for at
  least some shapes. Values come back redacted regardless. For normal
  verification, redacted output is enough: use
  `opendeploy services env get "$PROJECT_ID" "$SERVICE_ID" --json` and inspect
  key presence/source/duplicates. Inspect actual injected values only after
  explicit secret-reveal approval, then use
  `opendeploy services env get "$PROJECT_ID" "$SERVICE_ID" --show-secrets --json`.
- **`dependency_id` requires the catalog UUID,** not the friendly name (`mysql`,
  `postgres`, etc.). The API documentation calls this a string; in practice
  passing `"mysql"` returns `400 Invalid dependency_id format`. CLI `0.1.20+`
  ships `opendeploy dependencies catalog --json` to discover UUIDs. On older
  CLIs:
  ```bash
  curl -sS -H "Authorization: Bearer $OPENDEPLOY_TOKEN" \
       "${OPENDEPLOY_BASE_URL:-https://dashboard.opendeploy.dev/api}/v1/dependencies" \
    | jq -r '.dependencies[] | "\(.name)\t\(.id)"'
  ```
  Save the UUID and pass it as `dependency_id` in the create body.
- **`opendeploy services restart` may return `HTTP 503 Service Unavailable`**
  if a previous restart workflow for the same service is still in flight. Wait
  10–15 s and retry the same command. Do not fall through to redeploy.
- **Prefer `opendeploy services env patch --body env-patch.json` for secrets.**
  Current CLI releases accept a body file for env patch. Passing secret values
  via `--set KEY=value` exposes them in argv (`ps aux`, shell history), so use a
  mode-0600 JSON file for DB passwords, tokens, and any value that might be
  sensitive. Delete the patch file after the call.
- **`opendeploy deployments build-logs` may return `HTTP 400 Bad Request`** for
  terminal-failed deployments without a structured error envelope. Fall back to
  `opendeploy deployments logs "$DEPLOYMENT_ID" --query tail=300` which carries
  both build (`source: "buildctl"`) and runtime lines. Filter by `source` if
  you only want build output.
- **`services restart` does not propagate pod-spec changes.** Patches that
  affect `start_command`, `build_command`, `dockerfile_path`, or resource caps
  may not take effect on restart even though the CLI envelope says
  `restart_required: true`. After service-config changes that touch build/start
  fields, prefer `opendeploy deployments create` over `services restart`.
- **`start_command` for `builder: dockerfile` services may be silently
  dropped.** The field persists on the service row and `start_command_locked`
  flips to `true`, but the running pod executes the Dockerfile `CMD` directly.
  Verify via the migration smoke test in `references/deploy.md` Step 9.1; if
  the override didn't run, edit the Dockerfile `CMD` and re-upload source.

## Alarm inspection

Read-only:

```bash
opendeploy monitoring alarms --json
opendeploy monitoring alarms project/"$PROJECT_ID" --json
opendeploy monitoring alarms get "$ALARM_ID" --json
opendeploy monitoring alarms history "$ALARM_ID" --json
opendeploy monitoring alarms notes "$ALARM_ID" --json
```

Alarm lifecycle is not part of the normal deploy path. Use `opendeploy-alarms`
for notes, acknowledge, resolve, suppress, and alarm-backed legacy support
engagement. Use `opendeploy-oncall` when the user wants the agent to keep
OpenDeploy responders updated in an alarm's Discord thread or when the user
asks to engage OpenDeploy support for a CLI/platform failure with no alarm. In
the no-alarm case, run `opendeploy oncall status --json`; if there is no
channel, run `opendeploy oncall setup --json` and return the `authorize_url`.
Ask before any lifecycle mutation or support notification.

## Dangerous routes

Never call these from the skill with an `od_*` bearer token:

- `projects delete`
- `services delete`
- `domains delete`
- `dependencies delete`
- `secrets delete`
- `auth guest revoke`
- admin delete routes

For project/service/dependency/domain deletes, provide a dashboard handoff. For
env deletion inside an explicit env cleanup request, show a key-only diff and
use the narrow env route:

```bash
opendeploy services env unset "$PROJECT_ID" "$SERVICE_ID" "$KEY" --confirm-env-upload --json
```

Use `services env reconcile --from-plan ...` only when syncing a reviewed plan.
Never use full env replacement merely to delete one key.
After any env mutation, read back key names and ask before redeploy. App-visible
env requires a new deployment:

```bash
opendeploy deployments create --project "$PROJECT_ID" --service "$SERVICE_ID" --json
```

`services restart` has been observed not to refresh pod env after a service env
patch. Use restart only for non-env live-service actions or when a current
backend response explicitly proves restart refreshes pod env.
