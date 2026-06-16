# Deploy - upload, build, watch, report

Default execution is the versioned CLI. Do not use raw `curl` for the
first-deploy path. If a CLI command is missing or returns a known old-version
upload error, update to `@opendeploydev/cli@0.1.19+` and retry the CLI command.
Use `opendeploy-api` only for backend debugging after the CLI path is proven
unavailable.

Preconditions:

- `opendeploy preflight . --json` ran successfully.
- Auth is resolved. If no token exists, the agent used `AskUserQuestion` and
  the user approved local deploy credential creation or provided a dashboard token.
- Project, service, dependencies, and env were created through the resource
  commands in `references/setup.md`.
- `$PROJECT_ID`, `$SERVICE_ID`, `$PROJECT_NAME`, and `$REGION_ID` are known.
- For Node/JS services, package-manager determinism has been reviewed:
  `package.json.packageManager`, the matching lockfile, `.npmrc`, and
  Dockerfile package-manager commands agree. If the app has no lockfile or the
  Dockerfile uses unpinned Corepack/latest commands, resolve that with the user
  before spending cloud build time.

## Step 4 - Create a safe source archive

Run this before upload so the agent can inspect exactly what will be sent. CLI
`0.1.19+` performs smart packaging for mixed repos:

```bash
opendeploy archive create "$SOURCE_PATH" --json
```

Rules:

- Do not upload `.env`, `.env.*`, credential files, private keys, kubeconfig,
  `.git`, `node_modules`, build outputs, or cache directories. The smart
  archive excludes `.env` / `.env.*` for safety. If a framework requires a
  committed non-secret `.env` at runtime, recreate the safe defaults in the
  Dockerfile or entrypoint instead of hand-rolling an archive.
- Treat the CLI archive manifest as authoritative unless it is visibly wrong.
  Review `required_files`, `included_overrides`, `secret_like_entries`,
  `git_metadata`, and `warnings`; do not rebuild the ZIP manually just because
  the project has `.npmrc` or `build/`.
- Do not classify a directory as build output by name alone. Keep top-level
  `build/`, `cmd/`, `scripts/`, `tools/`, `.github/`, and similar
  project-owned or project-metadata directories when Dockerfile, Makefile,
  generators, or package scripts reference them.
- Keep `.npmrc` when it contains only build configuration. If it contains auth
  tokens or credentials, stop for explicit consent or strip/rewrite the secret
  before upload.
- If the build relies on Git metadata, prefer a build variable such as
  `GIT_COMMIT`, `APP_VERSION`, or `SOURCE_VERSION` instead of uploading `.git`.
- If `git_metadata.bind_mount` is true, stop before upload unless the plan
  already removed the `.git` bind dependency or replaced it with safe build
  variables. A worktree `.git` pointer file is not portable cloud build input.
- If the archive command reports secret-like entries, stop and use
  `AskUserQuestion` before sending any source.
- Prefer the CLI archive output path when passing a file to upload. Passing the
  source directory is also allowed in CLI `0.1.6+`; the CLI will package it with
  the same safe excludes.
- The source archive must have a `.zip` suffix. If a temporary file lacks that
  suffix, rename or copy it to a `.zip` path before upload.

Manifest review:

```bash
unzip -l "$ARCHIVE_ZIP" | sed -n '1,120p'
```

Compare the archive manifest against Dockerfile `COPY` / `ADD`, BuildKit bind
mounts, Makefile targets, `go generate`, package scripts, and manifest files.
If a required non-secret source file is missing, rebuild the archive before
upload; do not wait for the build to fail. Exception: if the missing file is a
required top-level `.env` containing only safe framework defaults, do not fight
the smart archive. Generate the static `.env` in the Dockerfile/entrypoint and
keep real secrets in service env.

## Step 4.5 - Upload and bind source

This step is required before deployment creation. Upload-only is not enough:
the backend build workflow reads `project.source_path`, which is set by the
extraction worker triggered by `upload update-source` or the multipart
`/complete` endpoint.

### 4.5.0 - Pick upload path by archive size

Read the archive size from the manifest (Step 4) and branch:

```bash
ARCHIVE_BYTES="$(printf '%s' "$ARCHIVE_RESULT" | jq -r '.archive_manifest.size_bytes // 0')"
MULTIPART_THRESHOLD=$((100 * 1024 * 1024))  # 100 MiB
```

- `ARCHIVE_BYTES <= 100 MiB` → use **single-shot** (`opendeploy upload update-source`, sub-section 4.5.1).
- `ARCHIVE_BYTES > 100 MiB` → use **chunked** (`/upload/multipart/*`, sub-section 4.5.2). Single-shot at this size buffers the whole body in gateway memory and risks Cloudflare's ~100 s edge timeout — both are hard ceilings, not tunable.

### 4.5.1 - Single-shot upload (archives ≤ 100 MiB)

```bash
UPLOAD_RESULT="$(opendeploy upload update-source "$PROJECT_ID" "$SOURCE_PATH" \
  --project-name "$PROJECT_NAME" \
  --region-id "$REGION_ID" \
  --json)"
SOURCE_STATUS="$(printf '%s' "$UPLOAD_RESULT" | jq -r '.source_status // "ready"')"
```

Expected output includes:

- `status: "bound"`
- `source_status: "extracting"` (async path, default for ZIP archives) or `"ready"` (small non-ZIP / sync-fallback)
- `project_id`
- `project_name`
- `region_id`

`source_path` is **empty in the response when extraction is async**. The
extraction worker populates the project row asynchronously; do not parse
`source_path` from the upload response anymore — read it from
`opendeploy projects get` after the worker flips status to `"ready"`.

If the gateway says `project_name`, `region_id`, or multipart field
`project_file` is missing, the CLI is too old or the command omitted required
flags. Update the CLI or rerun the command with the flags above. Do not switch
to raw API for this known path.

### 4.5.2 - Chunked upload (archives > 100 MiB)

The CLI does not currently expose a top-level multipart command; call the four
endpoints directly via `opendeploy-api` (the API escape hatch). Skim
`references/api-schemas.md` "Step 4-MP" for the full contract before issuing
calls. End-to-end shape:

```bash
TOTAL_SHA256="$(shasum -a 256 "$ARCHIVE_ZIP" | awk '{print $1}')"
PART_SIZE=$((64 * 1024 * 1024))   # 64 MiB per part is a good default
TOTAL_PARTS=$(( (ARCHIVE_BYTES + PART_SIZE - 1) / PART_SIZE ))
INIT_KEY="$(uuidgen)"

# 1. init
opendeploy-api POST /v1/upload/multipart/init \
  --header "Idempotency-Key: $INIT_KEY" \
  --data "{\"project_id\":\"$PROJECT_ID\",\"project_name\":\"$PROJECT_NAME\",\"region_id\":\"$REGION_ID\",\"total_size\":$ARCHIVE_BYTES,\"part_size\":$PART_SIZE,\"total_parts\":$TOTAL_PARTS,\"total_sha256\":\"$TOTAL_SHA256\"}"

# 2. parts (in any order; PUT raw bytes, not multipart/form-data)
for n in $(seq 1 "$TOTAL_PARTS"); do
  PART_FILE="$(mktemp)"
  dd if="$ARCHIVE_ZIP" of="$PART_FILE" bs="$PART_SIZE" count=1 skip=$((n-1)) status=none
  PART_SHA="$(shasum -a 256 "$PART_FILE" | awk '{print $1}')"
  opendeploy-api PUT "/v1/upload/multipart/$UPLOAD_ID/parts/$n" \
    --header "X-Part-SHA256: $PART_SHA" \
    --body "$PART_FILE"
  rm "$PART_FILE"
done

# 3. complete (returns immediately with source_status='extracting')
COMPLETE_KEY="$(uuidgen)"
opendeploy-api POST "/v1/upload/multipart/$UPLOAD_ID/complete" \
  --header "Idempotency-Key: $COMPLETE_KEY" \
  --data "{\"total_sha256\":\"$TOTAL_SHA256\"}"
```

If `complete` returns 409 with `missing_parts: [int, ...]`, re-PUT only those
parts — do not restart. If it returns 503 (extractor backpressure), retry
after 5 s.

### 4.5.3 - Wait for `source_status: "ready"` before deploying

Both paths now extract asynchronously. The deployment-service refuses to start
a build while extraction is in flight (409 + `Retry-After: 5`) or failed
(422 + `extraction_error`).

```bash
for i in $(seq 1 60); do                        # ~3 min cap; extraction is sub-minute typical
  STATUS="$(opendeploy projects get "$PROJECT_ID" --json | jq -r '.source_status // "ready"')"
  case "$STATUS" in
    ready)      break ;;
    extracting) sleep 3 ;;
    failed)     echo "extraction failed - re-upload"; exit 1 ;;
    *)          break ;;
  esac
done
```

If the upload returns 502/503/504 or another edge timeout after a long request,
the backend may still be processing, extracting, or may already have bound the
source. Do not immediately retry. First read back project/source state:

```bash
opendeploy projects get "$PROJECT_ID" --json
```

Retry only when `source_path` is empty AND `source_status` is not
`"extracting"`, OR `original_file_size` is zero, OR the bound source does not
match the intended archive. Continue to deployment creation only when the
project shows `source_status: "ready"` and a non-empty `source_path`.
After one read-back-confirmed large upload failure, switch to the multipart
path instead of repeating the same single-shot request. If using a split path
(`upload upload-only` then `upload update-source`), make sure the uploaded file
name ends in `.zip`.

## Step 5 - Env changes

Skip unless the user approved late env upload or rotation.

Preferred operations:

```bash
opendeploy services env patch "$PROJECT_ID" "$SERVICE_ID" --set KEY=value --json
opendeploy services env unset "$PROJECT_ID" "$SERVICE_ID" KEY --json
opendeploy services env reconcile "$PROJECT_ID" "$SERVICE_ID" --from-plan "$PLAN_PATH" --json
```

Do not use full replace for first deploy. Env delete is allowed for ordinary
keys, but deleting generated dependency keys such as `DATABASE_URL`,
`REDIS_URL`, or `MONGODB_URI` requires explicit user confirmation because it
disconnects a service from a managed dependency.

Log key names only, never values.

## Step 6 - Service config before deploy

Read back service config before deployment creation:

```bash
opendeploy services get "$SERVICE_ID" --json
```

If the service was created through CLI `0.1.12+`, prefer the create command's
own `verification.ok` field. It already read back and, if needed, patched a
dropped `port`, `port_locked`, or `start_command`. Treat
`verification.ok: false` as a hard stop before source upload or deployment
creation.

Required invariants:

- `port` matches the expected listener port.
- `port_locked` is true when the user or framework evidence fixed the port.
- `start_command` listens on the same port recorded in `port` unless it uses
  `$PORT` and the runtime env maps `$PORT` to that service port.
- `build_command` matches the plan when the plan requires a custom build.
- If an existing Dockerfile should be used, `dockerfile_path` is non-empty,
  points to a file inside the uploaded source tree, and `builder` reads as
  `dockerfile`.
- Prefer source-root `Dockerfile` when one exists. If multiple Dockerfiles
  exist, ask before selecting a non-root variant such as `Dockerfile.rootless`
  or a nested path such as `docker/Dockerfile`. If there is no Dockerfile and
  OpenDeploy autodetect/config can deploy the service, use that path. If
  preflight/plan reports `no_service_detected`, `no_package_or_dockerfile`, or
  a clear unsupported runtime shape, Dockerfile authoring is an allowed
  OpenDeploy continuation. If file-edit permission is already granted, write the
  minimal deployment files and continue; otherwise ask for structured
  source-edit approval. Follow `references/dockerfile-authoring.md`; for
  PHP/Laravel specifics, also use `references/dockerfile-php-laravel.md`. Show
  the generated files for review before upload.
- If Dockerfile or compose exposes multiple ports, the service port is the HTTP
  listener. Unsupported secondary protocols such as SSH, SMTP, or raw TCP must
  be called out before deploy and disabled/left unsupported only with user
  approval.
- If the app needs persistent filesystem state, pause before mutation and ask
  for the OpenDeploy storage strategy. Options: attach an OpenDeploy volume
  (recommended for local uploads, backups, media, SQLite, file queues, repo
  storage, or other fixed filesystem paths), configure the app's
  object-storage/media env when it is already designed for external object
  storage, continue with ephemeral local files after explicit data-loss
  acknowledgement, or review details. Never auto-attach a volume. For a new
  service in this deploy, include `volumes` inline in `service.json` on
  `services create` (StatefulSet from the start, no downtime). For an existing
  service, route to `opendeploy-volume` for the workload-conversion
  confirmation. Do not call the deploy a preview and do not suggest another
  platform unless the user asks.
- Do not set installer-lock/setup-complete flags unless the plan includes the
  required admin/bootstrap step or the user approves that setup choice.
- If managed DB/cache dependencies were created, their generated env keys are
  present on the service before deploy creation.

If the app already has a Dockerfile and the plan uses Dockerfile mode, patch
and verify the exact path:

```bash
opendeploy services config patch "$SERVICE_ID" \
  --dockerfile-path "$DOCKERFILE_PATH" \
  --json

opendeploy services get "$SERVICE_ID" --json
```

After this read-back, the backend must not fall back to an auto language
builder. The proof is in the first build logs: they should show Dockerfile mode,
not Railpack/autodetect. If logs show autodetect while Dockerfile mode was
planned, stop and report the mismatch; do not create a Dockerfile automatically.
If Dockerfile build fails, report the Dockerfile build error instead of retrying
with an auto provider.

## Step 7 - Create deployment

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

Capture the returned deployment id as `$DEPLOYMENT_ID`.

Do not leave deployment-history fields blank. For local agent uploads, set
`SOURCE_KIND=upload`, `PACKAGE_FILE` to the uploaded package filename, and
`BOUND_SOURCE_PATH` to the `source_path` returned by upload/update-source. The
backend also snapshots runtime/build variables at deployment creation. When the
agent has just patched or synthesized env vars in this flow, prefer writing a
0600 `deployment.json` body that includes `runtime_variables` and
`build_variables`, then run `opendeploy deployments create --body
deployment.json --json`; this keeps deployment history accurate even if the
service env changes later. Preserve the exact split from the deploy plan:
runtime variables are for the running app, build variables are for build
commands. Do not set both fields to the same full env map unless every overlap
has explicit source evidence.

## Step 8 - Wait and diagnose

```bash
opendeploy deploy wait "$DEPLOYMENT_ID" --follow --json
```

The command emits JSONL progress events. Surface `progress_percent` on every
user-visible waiting update. When `phase` is `building`, also surface
`build_percent` if present. Do not report only "still building"; say e.g.
`Build 42% — still installing dependencies`.

Prefer `opendeploy deploy wait` over handwritten shell polling. If polling is
unavoidable, use a readable `while true; do ...; done` block. Do not compress
`until`/`case` loops into one-liners; zsh parse errors such as `parse error near
done` waste deploy attempts and hide the real deployment state.

On success, proceed to the final report.

Before printing the success contract, run a quick app-level smoke check:

- fetch the documented health/readiness path when the repo exposes one; use the
  live root only when it is a real public page and not an installer/auth/setup
  flow
- for DB-backed frameworks, check one endpoint that exercises the app's DB path
  when the repo exposes an obvious candidate, such as `/graphql/` for GraphQL
  APIs
- if the app returns 5xx and runtime logs show missing migrations, missing env,
  or DB connection errors, invoke `opendeploy-debug` and fix the concrete cause
  before printing "Deployment successful"
- if OpenDeploy service health is green but the public edge returns 502/503 and
  app logs do not see the request, treat it as route/ingress convergence rather
  than an app crash. Read domain/service metadata, wait briefly, and engage
  OpenDeploy support if it persists. Do not keep redeploying the app without a
  code or config change.

If only a non-critical optional endpoint fails, print the normal report and add
a short follow-up note. Do not use health `200` alone as proof that a
DB-backed app is functionally ready when a known primary endpoint returns `500`.

Do not create a `ScheduleWakeup`, reminder, or long-running follow-up for a
normal one-shot deploy. The deploy wait/monitor stream is enough. If a wakeup
was accidentally created during troubleshooting, cancel or explicitly mark it as
irrelevant before the final report.

On failure:

```bash
opendeploy logs diagnose "$DEPLOYMENT_ID" --json
opendeploy deployments logs "$DEPLOYMENT_ID" --json
```

If build logs are needed and the CLI supports it:

```bash
opendeploy deployments build-logs "$DEPLOYMENT_ID" --json
```

Before any retry, pause, or terminal failure report, open
`references/deploy-attempt-record.md` and update the local attempt record with
deployment status, redacted log excerpt, stable `error_category`, root cause,
and the next action. Append the compact JSONL line too. This turns failed
deploys into reusable evidence instead of one-off chat history.

Retry budget:

- One automatic retry is allowed only after a concrete read-back verified
  change, such as service port, start command, missing env key, or Dockerfile
  config.
- Do not create/edit `Dockerfile`, `.dockerignore`, package scripts, or app
  runtime code without explicit user approval. For first deploy, Dockerfile
  authoring is appropriate when autodetect cannot deploy but source evidence is
  clear enough to produce a minimal container (for example a Go service with
  `go.mod` plus `cmd/server/main.go` listening on `$PORT`). Use
  `references/dockerfile-authoring.md`, list the exact files, and ask via
  structured source-edit consent before editing. Once the user has approved a
  Dockerfile iteration cycle, each retry derived from a concrete log error
  counts as one fix; ask again before any change to `composer.json`,
  `package.json`, framework config, or app runtime code.
- If logs return 401/403 for an unbound local deploy credential, stop and ask
  the user to bind the credential or provide an `od_k*` dashboard token. Do not keep retrying
  blind.

**Build cache reality.** A retry of the same Dockerfile against the same source
hits BuildKit layer cache on the backend. Expect the second build to be ~2x
faster than the first (e.g. 10 min cold -> 4 min warm). Budget timeouts and
user-facing waiting messages accordingly; do not abandon a retry at the
cold-build duration.

### Contact block on terminal failure

After diagnostics, print this block when the run is stopping in `failed`,
`cancelled`, or `rolled_back`. If the user explicitly asked to engage
OpenDeploy support, get a private Discord URL before printing: run
`opendeploy oncall status --json`; if no channel exists, run
`opendeploy oncall setup --json` and use the returned `authorize_url`. If the
user did not ask to engage support yet, set `<PRIVATE_DISCORD>` to
`Ask me to engage OpenDeploy support and I will return your private Discord
link.`:

```text
---

## Need help?

This deployment did not make it. If the diagnostics above do not make the
root cause obvious, reach out and we will look at it together.

- **Private Discord:** `<PRIVATE_DISCORD>`
- **Email:** hi@opendeploy.dev

When you contact us, please paste:

- **Project:** `<PROJECT_NAME>`
- **Project ID:** `<PROJECT_ID>`
- **Service:** `<SERVICE_NAME>`
- **Service ID:** `<SERVICE_ID>`
- **Deployment ID:** `<DEPLOYMENT_ID>`
- **Status:** `<STATUS>`
- **Attempt record:** `<ATTEMPT_RECORD_PATH>`
```

## Step 9 - Final report

Use the CLI report as the source of truth:

```bash
opendeploy deploy report "$DEPLOYMENT_ID" --json
```

The report returns:

- `live_url` or `app_url`
- `is_bound`
- `bind_url` when the local deploy credential is not yet linked to an account
- `dashboard_url` when the credential is account-bound

For Branch A / unbound local deploy credentials, `live_url` / `app_url` is for
internal verification and bind-link construction only. Do not surface it to the
user in the final answer or in follow-up binding prompts.

Never construct a bind URL by hand. It must include the CLI/API-provided
signature.

CLI `0.1.19+` writes `.opendeploy/project.json` from `deploy report` when the
deployment report includes `project_id`, `service_id`, `deployment_id`, and
`live_url`. If `context_save.saved` is false, run `opendeploy context save`
with the report fields before finishing so future `/opendeploy` calls do not
create duplicates or show `Deployment ID: none`.

Before printing any Branch A/B success report, update the deploy-attempt record
with `final.status`, live URL, dashboard/bind URL, deployment id, and remaining
caveats. If this was a retry, add a `fixes[]` entry describing the change and
redeploy result.

The Branch A/B block is the entire final answer. Do not append a second
summary, "How it was deployed", "Notes", file-change lists, caveats, memory
updates, or follow-up narration after the block. Put those details in the
deploy-attempt record instead. The user action must stay visually dominant.

### Step 9.1 — DB-backed framework smoke test (mandatory for django/rails/laravel/phoenix/prisma/drizzle/alembic)

If the deploy plan recorded a framework that requires schema migrations
(`django`, `rails`, `laravel`, `phoenix`, or any plan with
`migrations: required`), the deployment reaching `status: success` is **not**
sufficient evidence that the app actually serves real data. Before printing
the success banner, run one read-only check:

```bash
opendeploy services logs "$PROJECT_ID" "$SERVICE_ID" --query tail=200
```

Scan the most-recent pod's earliest entries for migration evidence:

| Pattern | Meaning |
|---|---|
| `Operations to perform`, `Applying \w+`, `Running migrations`, `migrations: ok`, `Loaded \d+ migrations`, `migrate deploy`, `Migration.*applied` | migrate ran |
| `relation ".*" does not exist`, `TableDoesNotExist`, `P2021`, `no such table`, `OperationalError`, `password authentication failed for user "<placeholder>"`, `role "<placeholder>" does not exist` | migrate did NOT run, or DB credentials are wrong |
| `Environment variable not found: .*DATABASE.*`, `Missing.*DIRECT.*URL`, `shadowDatabaseUrl` | migration env alias is missing |
| start command's first token or migration command (e.g. literal `python manage.py`, `bundle exec`, `php artisan`, `prisma migrate`) | the intended command path was honored |
| neither pattern present | the service command override may have been dropped — the pod ran the generated image command or Dockerfile `CMD` directly |

**If the failure pattern wins, do NOT print the success banner.** Demote to a
half-success report:

```text
## Deployment is live but the schema is not initialized

**Live URL:** <APP_URL>
**Dashboard:** <DASHBOARD_URL>

The web service started (HTTP 200 on `/health/`-style endpoints), but database
migrations have not run. Endpoints that touch the database will return errors
until migrations run.

**Likely cause:** the runtime command did not execute the migration path, or a
required migration env alias is missing.

**Suggested fix:**
1. Put migrations in the command path the image actually runs. For Dockerfile
   services, edit `CMD` / entrypoint; for package-manager auto-builder
   services, edit the package start script if that is what the image runs.
2. Add any missing migration-only DB URL aliases to the service env.
3. Re-upload source and create a new deployment.

**Project ID:** `<PROJECT_ID>`
**Service ID:** `<SERVICE_ID>`
**Deployment ID:** `<DEPLOYMENT_ID>`
```

Do **not** auto-edit the Dockerfile. Surface the half-success report and ask
the user before any source mutation.
Record this as `migration_missing` (or the closest stable category from
`references/deploy-attempt-record.md`) in the deploy-attempt record before
asking for the next action.

### Branch A - unbound local deploy credential

Print exactly:

```text
## Deployment ready — bind project first

Your app has been deployed under a temporary guest project. Bind it now to keep
it running after the 6-hour guest window.

## Required action: [Bind project now](<BIND_URL>)

After binding, open the live app from the OpenDeploy dashboard.
```

Stop here. Do not print the live URL, project/service/deployment IDs,
deployment method, project file changes, or any extra explanatory text after
this block for unbound guest deploys. The bind link is the only user-facing URL
in Branch A.

### Branch B - account-bound credential

Print exactly:

```text
## Deployment successful

**Live URL:** <APP_URL>
**Dashboard:** <DASHBOARD_URL>

**Project:** `<PROJECT_NAME>`
**Service:** `<SERVICE_NAME>`
**Status:** `success`
**Project ID:** `<PROJECT_ID>`
**Service ID:** `<SERVICE_ID>`
**Deployment ID:** `<DEPLOYMENT_ID>`
```

Stop here. Do not append deployment method, notes, or memory/refinement text
after this block.

If `is_bound` is absent or ambiguous, do not print the live URL when the auth
state is `unbound`, `pending`, `binding_state: pending`, or when a `bind_url`
is present. Print the Branch A bind-first block if a valid `bind_url` is
available. If no valid bind link is available, report that binding is required
but the bind link could not be determined, and stop.
