# Setup Reference - CLI Only

Use this reference for the resource-creation half of first deploy:

```text
project -> managed dependencies -> dependency env -> services
```

Default execution is through `@opendeploydev/cli`. Do not use raw gateway
requests for setup. If a route is missing, hand off to `opendeploy-api` with
explicit user approval and report the CLI gap.

## Fixed Order

1. Create the project.
2. Create every managed DB/cache dependency required by the plan.
3. Wait until dependencies are ready.
4. Collect dependency env vars.
5. Merge dependency env into the consuming service env.
6. Create services with final port/start/root/env/resource config.
7. Read back service config and env keys before upload/deploy.

Do not deploy an app service before DB/cache env has been injected.

## Create Project

Pick the OpenDeploy default region from `opendeploy regions list --json`
without asking the user. Today the only user-facing region is `us-east-1`; if
the API later returns multiple active user-facing regions and no default, ask
with a structured question. Do not ask for a freeform region preference during
normal first deploy.
OpenDeploy has one user-facing deploy target: production. Do not ask the user
to choose production, staging, or preview, and do not pass `--environment` from
the skill.
Pass the region `id` to the CLI/API. If the API response still carries legacy
`name: "east-us-1"`, treat that as internal metadata and display `US East 1` /
`us-east-1` to the user. Do not print the region UUID/internal DB id in
user-facing updates.

```bash
opendeploy projects create \
  --name "$PROJECT_NAME" \
  --repo "${GIT_URL:-file://upload}" \
  --branch "${GIT_BRANCH:-main}" \
  --region "$REGION_ID" \
  --skip-validation true \
  --json
```

Save the returned project ID:

If `projects create` returns a 5xx, times out, or exits after a long request,
read back projects by stable name before retrying. Do not try several alternate
create bodies; the first request may already have committed. Continue only
after exactly one project id is resolved.

```bash
opendeploy context save --project "$PROJECT_ID" --json
```

For unbound local deploy credentials, the backend may limit the credential to 10
live guest projects. Multi-service apps should still fit inside one project
unless the repo truly contains separate deployable apps.

## Create Managed Dependencies

Create one dependency per detected engine:

```bash
opendeploy dependencies create --body .opendeploy/dependency.json --json
```

Before create, either generate strong credentials locally or wait for
user-provided credentials. Do not rely on backend defaults and do not use
`admin` / `changeme`.

Recommended generated path:

```bash
umask 077
mkdir -p .opendeploy
# Generate fresh values per dependency; keep values out of stdout.
# username: app_<8 random hex chars>
# password: app-compatible CSPRNG value; 32+ chars unless repo docs/env require
#           an exact/max length such as 16 chars
opendeploy dependencies create --body .opendeploy/dependency.json --json
```

The body should contain `project_id`, `dependency_id`, `username`, `password`,
and, for SQL/MongoDB, `database_name`. Generate passwords to satisfy the app's
documented constraints and OpenDeploy's backend validator. If no constraint is
documented, use 32+ chars; if the app requires exactly 16 chars or a max length,
generate that length with a safe charset such as `A-Za-z0-9_-`.

Before creating the dependency, compare the app's documented DB engine/version
requirement with the active OpenDeploy catalog. If app docs mention a newer
version than the catalog exposes, surface it as a verification note and
continue with the available managed dependency unless source evidence says the
app explicitly refuses that version or the user asked for an exact DB version.
Do not claim practical compatibility until the targeted smoke test passes. Keep
any post-deploy installer guidance key-only. If the web installer needs DB
values, point the user to the dashboard env reveal UI or the local mode-0600
dependency body file; do not print credentials in chat.

Then wait:

```bash
opendeploy dependencies wait "$PROJECT_ID" --json
opendeploy dependencies env "$PROJECT_ID" --json
```

Prefer `dependencies wait` over custom background monitors. If a monitor is
used, it must exit `0` while dependencies are `pending`, `deploying`, unchanged,
or temporarily unreadable. Exit non-zero only for terminal `failed` or command
errors. After any monitor exits non-zero, immediately run
`opendeploy dependencies status "$PROJECT_ID" --json`; if status is now
`running`, treat the monitor failure as a watcher bug and continue.

Required invariant before service creation:

- every planned dependency is `running` / ready
- dependency env keys are available
- every dependency key that the app will consume is non-placeholder. Evaluate
  `placeholder_secret_keys` against the service env contract. Unused alias
  placeholders are a key-only warning; consumed keys, generated connection URLs,
  or synthesized aliases must never carry values such as `changeme`, `password`,
  or `secret`
- **canonical and alias env keys agree.** Do not trust `DATABASE_URL` /
  `MONGODB_URI` / `REDIS_URL` over the alias group (`POSTGRES_USER`,
  `POSTGRES_DB`, `DB_USER`, `PGUSER`, `MYSQL_USER`, `MYSQL_DATABASE`, `MONGO_USER`).
  After `dependencies wait`, fetch `dependencies status --json`, parse
  `connection_info.username` and `connection_info.database`, and compare against
  the user/db parsed from the canonical URL. If they disagree, the canonical key
  is a placeholder fabrication — overwrite via `services env patch` using values
  copied from the alias group, or wrap `start_command`/Dockerfile `CMD` to
  construct the URL at runtime from the aliases. Document this as a known backend
  env-injection bug in the deploy plan
- generated env includes the framework's expected aliases, for example
  `DATABASE_URL`, `MYSQL_URL`, `MONGODB_URI`, `REDIS_URL`
- application-specific DB aliases from repo evidence are mapped from the
  managed dependency values before service creation. Examples include
  `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_PASS`,
  `POSTGRES_HOST`, `PGHOST`, and framework-specific nested keys. If the app
  expects host plus port in one variable, synthesize `host:port` from the
  dependency env instead of deploying and waiting for a connection failure.

If the dependency wait times out or env keys are missing, stop and diagnose.
Do not create a service and hope a later redeploy fixes it.

If a running dependency already exists with placeholder credentials, ask the
user whether to rotate to secure credentials and use the command below for
Postgres/MySQL/MongoDB. Do not use Redis `update-connection` as the normal
recovery path for first deploy or auth failures; recreate the Redis dependency
or engage OpenDeploy support instead.

```bash
opendeploy dependencies update-connection "$PROJECT_ID" "$PROJECT_DEPENDENCY_ID" \
  --body .opendeploy/db-credentials.json \
  --json
```

After rotation, run `opendeploy dependencies wait/env`, patch/reconcile the
updated env into every consuming app service, and create new deployments before
assuming the app uses the new password.

Redis auth rules:

- Prefer the exact `REDIS_URL` returned by `opendeploy dependencies env/status`.
  Do not synthesize a different password or rotate Redis just because an app
  expects a service-specific key such as `PAPERLESS_REDIS`; map that key to the
  returned Redis URL.
- If the app needs a URL variant, change only the shape (`redis://:PASS@host`,
  `redis://default:PASS@host`, database suffix such as `/0`) from the returned
  values. Do not call `dependencies update-connection` for this.
- If runtime logs say `invalid username-password pair` or `user is disabled`
  after Redis `update-connection`, stop immediately. Further rotations and
  redeploys are unlikely to help. Ask the user to delete/recreate the Redis row
  in the dashboard, or engage OpenDeploy support with project/dependency/service
  and failed deployment IDs.

**`services env patch` may leave duplicate rows.** The backend
`service_variables` table allows multiple rows per `(service_id, key, type)`
distinguished by `source: "user"` vs `source: "dependency"`, with no enforced
winner. After any patch that overwrites a dependency-managed key
(`DATABASE_URL`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_NAME`,
`MONGODB_URI`, etc.), do
`opendeploy services env get "$PROJECT_ID" "$SERVICE_ID" --json` and assert
each patched key appears exactly once in the `variables` array. Redacted output
is enough for duplicate-key detection; do not use `--show-secrets` unless the
user explicitly asked to reveal values. If a key appears twice, your patched
value may be shadowed at deploy time. Treat this as a backend bug and switch to
a runtime override (Dockerfile `CMD` exporting the value from the alias env)
instead of trying to win the patch race.

## Env Merge Rules

Merge order:

1. local plan defaults
2. user real non-empty values approved by env-upload consent
3. managed DB/cache generated values
4. explicit user-approved conflict override

Rules:

- empty strings do not override managed dependency values
- placeholders from `.env.example` do not override managed dependency values
- values from `.env.example`, `.env.sample`, and `.env.template` do not enter
  `runtime_variables` or `build_variables`; they only identify key names and
  defaults for planning
- if user-supplied `DATABASE_URL` conflicts with a managed DB URL, ask whether
  to use the external DB or the OpenDeploy managed DB
- DB/cache generated env wins when the user chose managed dependencies

## Create Services

Build a `service.json` file with the final values, then:

```bash
opendeploy services create "$PROJECT_ID" --body service.json --json
```

Before creating, read/list services in the project and reuse or patch a
matching service name. If create returns 5xx or times out, read back by stable
service name before retrying. Do not create duplicate services while trying
alternate schema shapes.

The create result must include `verification.ok: true`. If it does not, do not
upload source or create a deployment; fix the reported mismatch first. The
expected service config includes the chosen listener `port`, matching
`start_command`, `build_command`, and any dependency env vars.

`service.json` should include:

- `name`
- `type` (`web` for an HTTP service, `worker` for a background service,
  `cron` for scheduled work, `static` only for static-site service mode)
- `language`
- `framework`
- `port`
- `runtime_variables`
- `build_variables`
- resource caps appropriate for the credential
- `dockerfile_path: "Dockerfile"` when a source-root `Dockerfile` already exists

Env schema is exact. The backend/CLI field names are `runtime_variables` and
`build_variables`. Do not use aliases such as `runtime_env`, `runtime_envs`,
`env`, `environment_variables`, `runtimeVars`, `build_env`, or
`buildtime_variables`; those can be ignored and create a service with empty env.
Do not put the same env map into both exact fields. Classify keys first:
runtime values are read by the running app, while build values are read by
Dockerfile `ARG`, package/build scripts, or client compile-time public prefixes.
Duplicate an individual key only when source evidence shows both phases need it.
Before calling `services create`, validate the body shape locally and compare
the planned key set against these two maps:

```bash
jq -e '.type as $t | ($t == "web" or $t == "worker" or $t == "cron" or $t == "static")' service.json
jq 'has("runtime_env") or has("runtime_envs") or has("env") or has("environment_variables") or has("runtimeVars") or has("build_env") or has("buildtime_variables")' service.json
jq -r '(.runtime_variables // {}) | keys[]' service.json
jq -r '(.build_variables // {}) | keys[]' service.json
```

The first command must exit 0. The second command must print `false`. If the
app/dependencies require env keys, the third/fourth commands must show the
planned key names before mutation. If `services create` returns
`CreateServiceRequest.Type` / `Type required`, fix the same `service.json` by
adding the correct `type` and retry once after reading back by stable service
name; do not create a second service.

Set the detected port explicitly. If a framework has a strong port default
(for example Vite preview 4173 or Next.js 3000), record why the port was chosen
in the plan. Do not let generic Node defaults override framework or user
evidence.

For multi-port containers, set the HTTP listener as `port`. OpenDeploy first
deploy does not expose secondary raw TCP ports such as SSH/SMTP/database ports;
surface the HTTP-ingress behavior before mutation and do not describe the
result as protocol-compatible for secondary raw TCP ports unless those ports are
supported.

For planned persistent volumes, do not rely on inline `volumes` inside
`service.json` as the only proof of persistence. After service creation, list
volumes for the service. If the planned mount is absent, route through
`opendeploy-volume` and add it with the dedicated volume command/API before
source upload and deployment creation. Verify the volume row is active or
pending before continuing.
If volume add returns `403 quota_exceeded`, stop the volume path immediately
and ask with `Upgrade plan (Recommended)` first. Do not try smaller sizes unless
the user explicitly chooses resource adjustment.

Dockerfile mode rule: use Dockerfile mode when the project already has a
source-root `Dockerfile`. If no Dockerfile exists, use autodetect plus explicit
build/start/port config when that produces a runnable service. If autodetect
cannot identify a service but local evidence clearly identifies the runtime,
entrypoint, and HTTP port, Dockerfile authoring is allowed after structured
source-edit approval; follow `dockerfile-authoring.md` and create a source-root
`Dockerfile`, not `Dockerfile.opendeploy`. If the repo has `docker/Dockerfile`
or another nested Dockerfile, ask before changing the source root or
copying/renaming it.

If the app declares persistent storage (`VOLUME`, compose volumes, uploads,
media, repo/data directories), ask before creating resources. The OpenDeploy
path is a production deploy plan with an explicit storage decision: configure
the app's object-storage/media env first, attach a per-service persistent
volume, or continue with ephemeral local files after explicit data-loss
acknowledgement. Recommend the volume path for uploads/media/user-created files
even for demos/templates; ephemeral is only a throwaway choice after explicit
data-loss acceptance. Never auto-attach a volume. For a new service in this deploy,
include `volumes` inline in `service.json` on `services create` (StatefulSet
from the start, no downtime). For an existing service, route to
`opendeploy-volume` (first volume triggers a destructive
Deployment→StatefulSet conversion with ~30s downtime). Do not promise
persistence through Postgres when the app also stores important files on disk,
and do not suggest another platform unless the user asks.

When the selected storage path is external object storage, get the secret source
before any cloud mutation. Use structured secret input when available, or ask
for a local 0600 env/body file path. The agent runs the later OpenDeploy env
patch commands; do not make the user copy a block of `opendeploy services env
patch` commands as the default flow.

If the app has installer/admin bootstrap flags, do not set lock/skip-install
variables automatically. Either leave the installer flow enabled, provision the
required admin/bootstrap state through a supported command, or ask the user to
approve a locked setup with its consequence.

## Read-Back Verification

Before source upload/deployment:

```bash
opendeploy services get "$SERVICE_ID" --json
opendeploy services env get "$PROJECT_ID" "$SERVICE_ID" --json
```

Verify:

- service exists under the planned project
- service id/name match the intended service in the multi-service graph
- port matches the plan
- `type`, public/internal setting, build/start command, `source_path`, and
  `dockerfile_path` match the plan for that specific service
- required env keys are present
- DB/cache env keys are present before deployment
- no env values are printed in the final answer

If the service was expected to have runtime/build env and the read-back is
empty or missing required keys, stop before upload/deployment. First check
whether `service.json` used a wrong alias such as `runtime_env`; if so, patch
the env with `opendeploy services env patch --body ... --confirm-env-upload`,
read back again, and only then continue. If verification fails for any reason,
patch the service/env and verify again before moving to upload/update-source.

For multi-service projects, keep a service identity matrix before the first
deployment:

| service | id | kind | public/internal | port | source_path | dockerfile_path | build/start evidence |
|---|---|---|---|---|---|---|---|

Use it during failure recovery. If a deployment log, version record, or runtime
resource name indicates that service A is building service B's Dockerfile/image
or listening on service B's port, stop normal retry/rollback loops and report a
service mapping/platform inconsistency with the project/service/deployment IDs.
Do not create replacement services until the user approves that recovery path.
