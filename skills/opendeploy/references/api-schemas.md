# API schemas - opendeploy

Full field reference for every gateway endpoint the `opendeploy` skill touches. Grouped by pipeline step.

**URL convention**: `OPENDEPLOY_BASE_URL` includes the `/api` prefix (e.g. `https://dashboard.opendeploy.dev/api`). Endpoint paths below are written as `/v1/...` - the full request URL is `$OPENDEPLOY_BASE_URL/v1/...`. All calls send `Authorization: Bearer $OPENDEPLOY_TOKEN`. UUIDs are v4 strings.

Default error envelope (unless a step overrides):
- 401 - bad or expired API key.
- 403 - subscription / quota gate hit, **or `agent_delete_forbidden` on any HTTP `DELETE`** — see below.
- 404 - wrong ID.
- 409 - conflict (duplicate name / domain).
- Body shape: `{"error": "..."}`.

> **Skill-wide DELETE gate.** The gateway rejects every `DELETE` issued under an `od_*` Bearer token (both `od_k*` dashboard PAT and `od_a*` local deploy credential) with `403 {"error":"agent_delete_forbidden", "message":"...", "method":"DELETE", "path":"..."}`. This blanket gate applies to every endpoint in this document — schemas marked "DELETE" below are reachable only from the dashboard's signed-in OIDC session, never from this skill. SKILL.md Execution rule 17 enforces the same guarantee on the client side; this is the server-side mirror.

---

## Step 0 - POST `/v1/client-guests/register` (gateway, anonymous)

Create a local deploy credential on cold start when `~/.opendeploy/auth.json` is missing or its `api_key` is empty. **No auth required.** The skill writes the response into `~/.opendeploy/auth.json` (mode 0600) only after explicit user approval and uses Bearer mode for everything else.

- **Body** (optional):
  | field | type | required | note |
  |---|---|---|---|
  | `source_hint` | string | optional | free-form tag, e.g. `"claude-code/Darwin"`. Logged for triage; not persisted. |
  | `name` | string | optional | user-facing label, ≤ 64 chars after trim. Becomes the default name on the credential row; user can override on the account-binding page or rename later via PATCH. |
  | `hostname` | string | optional device label | The skill does not send this by default. Older clients may send it for triage; omit unless the user explicitly wants device labels. |
- **Rate limit**: 5 / hour / source IP. 429 with `Retry-After` on overage. Don't retry inside the skill — surface the wait to the user.
- **Idempotency**: Within 24h the same `(source_ip, user_agent)` calling again returns the same pending row. On replay the `api_key` field is omitted (the plaintext is never re-shown). If the skill's local `auth.json` is missing AND a replay returns no plaintext, surface a friendly error rather than retrying.
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `guest_id` | uuid | persist into `auth.json.guest_id` |
  | `api_key` | string | `od_a` + 43 base62 chars; persist into `auth.json.api_key`. **Omitted on idempotent replay** — see above. |
  | `gateway` | string | echoes the API base URL the skill should use; persist into `auth.json.gateway` |
  | `bind_sig` | string | hex MAC; persist into `auth.json.bind_sig`. Used by the skill only to construct the account-binding URL — never sent to the user standalone. |
  | `name` | string | echoes the persisted label. On replay this is whatever the user has curated since (e.g. via the account-binding page or PATCH); on first creation it equals the request body or the server-side default. The skill does not persist it — name lives server-side. |
  | `bind_url` | string | **IGNORED by the skill.** Server-built handoff URL with the shape `https://<dashboard_host>/guest/<guest_id>?h=<bind_sig>`. The skill always derives the account-binding URL locally as `${OPENDEPLOY_BASE_URL%/api}/guest/<guest_id>?h=<bind_sig>` and ignores this field on read. After deploy the skill appends `url=<APP_URL>` before printing to the user. |
  | `expires_in_seconds` | int | resource GC horizon (6 hours). Token itself is NOT expired by this; only the project resources are. |

### Bind / list / rename / revoke (OIDC-only, dashboard surface)

These exist for completeness; the **skill never calls them**. The user's browser does, after SSO. Listed here so failure-playbook can describe what 401 means when one is hit.

- `GET  /v1/client-guests/:guest_id/status?h=<bind_sig>` — anonymous, sig-authenticated. Returns `{ guest_id, state, name, hostname, created_at, last_deployed_at, expires_at }` so the account-binding page can pre-fill the rename input before the user signs in.
- `POST /v1/client-guests/:guest_id/bind` — body `{ "sig": "<bind_sig>", "name": "<optional override>" }`. Verifies the HMAC, transitions the credential to `state=bound`, atomically updates ownership for every internal project row matching that credential, and (when `name` is non-empty after trim) overrides the persisted label. Returns `{ guest_id, bound_at, name, project_ids }`.
- `GET /v1/client-guests` — list bound local deploy credentials for the OIDC user. Each item carries `guest_id`, `name`, `hostname`, `prefix`, `bound_at`, `source_ip`, `source_user_agent`, `last_deployed_at`.
- `PATCH /v1/client-guests/:guest_id` — owner rename. Body `{ "name": "..." }`. Trim + ≤ 64 chars; empty rejected with 400 `name_required`.
- `DELETE /v1/client-guests/:guest_id` — soft-delete + Redis pub-sub invalidation. **Dashboard-only** — skill `od_*` Bearer tokens hit `403 agent_delete_forbidden`.

### What's gone (do NOT call)

Older HMAC request-signing flows are stale. Every request now uses `Authorization: Bearer od_*` and the client-agent register/bind lifecycle above.

---

## Preamble

### GET `/v1/profile`
User-profile read for dashboard tokens and account-bound local deploy credentials only. **Do not use this as the preflight sanity check** because local credentials not yet linked to an account authenticate as guest tenants and are expected to 401 here.

- **Response 200**: `{"id": uuid, "email": string, "plan": string, ...}`
- **401** -> expected for local credentials not yet linked to an account. Only treat as invalid when the caller expected a dashboard token or account-bound credential.

### GET `/v1/regions` (cluster-service passthrough)
Sanity-check the Bearer token and discover an active region; required for `POST /projects` and `POST /upload/upload-only`. This endpoint works for dashboard tokens, account-bound local credentials, and local credentials not yet linked to an account.
Normal agent deploys should use the active OpenDeploy default region
(`us-east-1`) without asking for a user preference.

- **Response 200**: array of
  | field | type | note |
  |---|---|---|
  | `id` | uuid | pass as `region_id` / `OPENDEPLOY_REGION_ID` |
  | `name` | string | |
  | `code` | string | |
  | `status` | string | `active` / `inactive` - pick first `active` |
  | `environment` | string | internal platform value; do not expose as a user choice |

---

## Step 3.1 - POST `/v1/projects` (project-service)
Create a project.

- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `name` | string | yes | lowercase, DNS-safe |
  | `repo_url` | string | yes | for non-Git sources use any placeholder + `skip_validation:true` |
  | `branch` | string | optional | default: repo HEAD |
  | `token` | string | optional | Git token for private repo |
  | `build_config` | string (JSON) | optional | |
  | `deploy_config` | string (JSON) | optional | |
  | `region_id` | uuid | optional | server uses `DEFAULT_REGION_ID` if omitted |
  | `skip_validation` | bool | optional | set `true` for ZIP / folder sources |
  | `description` | string | optional | |
- **Response 201**: full `Project` object - `id`, `name`, `repo_url`, `branch`, `region_id`, `created_at`.
- **Errors**:
  - 400 on Git validation failure - body includes `error_code`, `error_message`, optional `available_branches`, `default_branch`.
  - 409 duplicate name.

---

## Step 3.2 - POST `/v1/dependencies/create` (build-service)
Provision a database dependency for the project. Only call if Step 2.5 flagged a DB. `service_id` is intentionally omitted - we bind via env_vars on service creation at Step 3.3.

- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `project_id` | uuid | yes | from Step 3.1 |
  | `dependency_id` | string | yes | `postgres` / `mysql` / `mongodb` / `redis` (extend as backend supports) |
  | `template_id` | string | optional | picks a non-default template (e.g. `postgres-15`) |
  | `environment` | string | optional | omit from agent commands; CLI `0.1.14+` fills the single internal target |
  | `service_id` | uuid | optional | **leave empty** at this stage - no service exists yet |
  | `display_name` | string | optional | user-visible name |
  | `username` | string | optional | custom DB user |
  | `password` | string | optional | server generates if omitted |
  | `database_name` | string | optional | custom DB name |
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `id` | uuid | instance id of the provisioned dep - collect into `DEPENDENCY_IDS_JSON` |
  | `dependency_id` | string | echo |
  | `name` / `display_name` | string | |
  | `type` | string | `postgres`/`mysql`/... |
  | `status` | string | `provisioning` -> `running` |
  | `environment` | string | internal platform value |
  | `env_vars` | map[string]string | **inject into every consumer service's `runtime_variables`** - typically `DATABASE_URL`, and per-DB fields (e.g. `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`) |
  | `message` | string | |

### Related: GET `/v1/dependencies/status/:project_id`
Optional readiness polling before Step 7.

- **Response 200**: `{ "dependencies": [{ "id": uuid, "status": string, ... }] }`.

---

## Step 3.3 - POST `/v1/projects/:id/services` (project-service)
Create a service inside a project. Call once per detected service. `runtime_variables` is pre-merged: local plan defaults + DB `env_vars` + user-approved overrides.

- **Path params**: `id` = `PROJECT_ID`.
- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `name` | string | yes | DNS-safe |
  | `type` | string | yes | `web` (HTTP), `worker` (background), `cron`, `static` |
  | `environment` | string | internal | omit from agent commands; CLI `0.1.14+` fills the single internal target |
  | `language` | string | optional | from local analysis |
  | `framework` | string | optional | from local analysis |
  | `port` | int | optional | |
  | `source_path` | string | optional | subfolder in a monorepo |
  | `dockerfile` | string | optional | inline Dockerfile content |
  | `dockerfile_path` | string | optional | path within the tarball |
  | `build_context` | string | optional | |
  | `build_command` | string | optional | |
  | `build_variables` | map[string]string | optional | build-time env (for `ARG` / `NEXT_PUBLIC_*` etc.) |
  | `runtime_variables` | map[string]string | optional | **pre-merged local plan + DB `env_vars` + user-approved overrides** |
  | `health_check_path` | string | optional | |
  | `readiness_path` | string | optional | |
  | `cpu_request` / `cpu_limit` | string | optional | K8s strings - we set `500m` / `2` |
  | `memory_request` / `memory_limit` | string | optional | `1Gi` / `4Gi` |
  | `replicas` | int | optional | default 1 |
  | `auto_scaling` | bool | optional | |
  | `dependencies` | []string | optional | sibling **service names** this one needs (not DB dep IDs) |
  | `internal_only` | bool | optional | blocks external ingress |
  | `volumes` | []object | optional | persistent volumes; presence forces `replicas=1` and renders the workload as a StatefulSet (see **Volume sub-schema** below) |
- **Response 201**: `{ "message": "Service created successfully", "service_id": "<uuid>" }` - **not** a full Service object. Parse `.service_id` (fall back to `.id` for older builds). If the caller needs resource/env spec back, follow up with `GET /v1/services/<service_id>`.

  Env field names are not aliases. `runtime_env`, `runtime_envs`, `env`,
  `environment_variables`, `runtimeVars`, `build_env`, and
  `buildtime_variables` are invalid for this API surface. They can be ignored
  by older backends instead of rejected, which produces a service with empty
  env. Agents must validate the body locally and read back env key names before
  source upload or deployment creation.

  **Volume sub-schema** (each entry in `volumes`):
  | field | type | required | note |
  |---|---|---|---|
  | `name` | string | yes | RFC 1123 label, ≤32 chars; drives the K8s PVC name template |
  | `mount_path` | string | yes | absolute path inside the container (e.g. `/var/lib/data`); `/etc`, `/usr`, `/bin` and other system dirs are rejected |
  | `size` | string | yes | K8s quantity (e.g. `5Gi`, `100Mi`). Validated server-side against the user's plan storage cap |

  Adding the **first** volume to an existing service is destructive: the
  service's existing Deployment is deleted and a StatefulSet is created in
  its place, with ~30 seconds of downtime while the new pod starts. The
  skill must surface this in chat before applying.

> **Encryption-at-rest (server-side, transparent to skill):** sensitive values
> in `runtime_variables` and `build_variables` are encrypted with the platform
> AEAD key before being persisted (`PASSWORD`/`PASSWD`, token/secret/private
> keys, and DB/cache URL keys are always treated as sensitive). The skill keeps
> sending **plaintext** over TLS — do not pre-encrypt. `GET /v1/services/<id>`
> and `GET /v1/projects/:id/services/:sid/env` return values decrypted by the
> gateway for agent read/modify/write flows, while dashboard list views mask
> sensitive rows by `is_encrypted=true`.

---

## Step 4 - POST `/v1/upload/upload-only` (project-service)
Park the source on the build-service. Does **not** analyze or plan. Either `project_file` or `git_url` must be set.

- **Content-Type**: `multipart/form-data`
- **Form fields**:
  | field | type | required | note |
  |---|---|---|---|
  | `project_name` | string | yes | |
  | `description` | string | optional | |
  | `region_id` | uuid | yes | must be an `active` region |
  | `project_file` | file | conditional | required unless `git_url` set. **ZIP only** - backend handler uses `archive/zip`; tar/tar.gz is rejected |
  | `git_url` | string | conditional | required unless `project_file` set |
  | `git_token` | string | optional | Git token for private repo |
  | `branch` | string | optional | default branch auto-detected |
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `temp_file_path` | string | pass to `POST /deployments` as `temp_file_path` |
  | `filename` | string | original filename (file path) |
  | `git_url` | string | set when git path |
  | `branch` | string | set when git path |
  | `is_git` | bool | |
- **Errors**: 400 missing file/url, invalid region, Git validation failed (body may include `error_code`, `error_message`, `available_branches`, `default_branch`).

> Do not call `/analyze-only`, `/analyze-from-upload`, `/analyze-env-vars`, `/create-from-analysis`, or any `/analyze*` endpoint. They are not part of agent-first deploy.
>
> **Caveat - this endpoint alone is not enough.** It parks the ZIP in a shared tmpdir; it does **not** attach the archive to any project, extract it, or populate `project.source_path`. The Temporal deployment workflow reads `deployment.SourcePath` (copied from `project.source_path`) - it does **not** read `TempFilePath` from the deployment row (see `shared/temporal/workflows/deployment.go:1774` -> `agent-service/.../activities.go:431`). You must follow up with Step 4.5 (`/upload/update-source`) before `POST /deployments`, or the build activity immediately fails because `filepath.Join("", "Dockerfile") == "/Dockerfile"` doesn't exist.

> **Size guard - `> 100 MiB` archives MUST use the multipart path (Step 4-MP) instead.** `/upload/upload-only` is proxied through the gateway's *buffered* path: the entire request body is read into gateway memory before the upstream call (`io.ReadAll(c.Request.Body)` in `gateway/internal/routes/proxy.go`). At 100 MiB × N concurrent uploads, gateway pods OOM. Cloudflare's edge timeout (~100 s) is a second hard ceiling — large bodies on residential uplinks frequently exceed it. The dashboard frontend already routes archives over 100 MiB to multipart automatically; agents calling the API directly must do the same.

---

## Step 4-MP - Chunked upload via `/v1/upload/multipart/*` (project-service)

Required when the archive is larger than 100 MiB. Replaces Step 4 + Step 4.5; runs end-to-end without `temp_file_path`.

The protocol is four endpoints: `init` opens a session, `parts/N` streams each chunk, `complete` finalizes and triggers async extraction, `abort` cancels. The gateway uses a streaming proxy for these routes (no body buffering, 600 s per-attempt timeout, isolated circuit breaker — see `slowUploadPathPrefixes` and `multipartUploadPathPrefix`).

### Step 4-MP.1 - POST `/v1/upload/multipart/init`

Opens a session and reserves an NFS staging file.

- **Headers**: `Idempotency-Key: <uuid>` required. Same key + same `(owner, project_id)` replays the prior `init` response — safe to retry on network blips.
- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `project_id` | uuid | yes | existing project from Step 3.1 |
  | `project_name` | string | yes | used for the eventual ZIP filename |
  | `region_id` | uuid | yes | matches the project's region |
  | `total_size` | int | yes | exact byte count of the assembled archive |
  | `part_size` | int | yes | every part except the last must be exactly this size; recommended 16-90 MiB |
  | `total_parts` | int | yes | `ceil(total_size / part_size)` |
  | `total_sha256` | string (hex) | yes | SHA-256 of the assembled archive; verified at `complete` |
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `upload_id` | uuid | thread through to subsequent calls |
  | `part_size` | int | server-confirmed |
  | `expires_at` | timestamp | session GC deadline (default 24 h, no part activity → cleanup) |
- **Errors**: 400 invalid sizes, 403 ownership, 404 project, 409 quota (concurrent session cap, total_parts cap, total_size cap).

### Step 4-MP.2 - PUT `/v1/upload/multipart/{upload_id}/parts/{part_number}`

Streams one part. Parts can be uploaded in any order and concurrently.

- **Path params**: `part_number` is `1..total_parts` (one-indexed).
- **Headers**: `Content-Length` and `X-Part-SHA256: <hex>` required. Mismatched SHA-256 → 400, the part is not persisted.
- **Body**: raw bytes of the part. **Not** multipart/form-data; the body IS the part.
- **Behavior**: the part is persisted to NFS at the precomputed offset. Re-PUT of the same part_number with the same SHA-256 is idempotent; with a different SHA-256 it overwrites (last-writer-wins until `complete` finalizes the session).
- **Response 200**: `{ "received": true, "part_number": N }`.
- **Errors**: 400 size mismatch, 400 sha256 mismatch, 409 session is `finalizing`/`complete`/`aborted`, 413 part oversized, 416 part_number out of range.

### Step 4-MP.3 - POST `/v1/upload/multipart/{upload_id}/complete`

Finalizes the session, hardlinks the assembled archive into the project's permanent storage, and **enqueues async extraction**. Returns immediately with `source_status: "extracting"`.

- **Headers**: `Idempotency-Key: <uuid>` required (separate from the init key). Same key on a `complete`-state session replays the cached response, enabling safe retry across a lost 200.
- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `total_sha256` | string (hex) | yes | must match init-time value; backend re-hashes the assembled file before flipping state |
  | `analysis` | object | optional | local agent/CLI plan metadata; same shape as Step 4.5 |
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `project_id` | uuid | echo |
  | `source_path` | string | **empty until extraction completes**; populated on the project row by the worker, surfaced via `GET /projects/:id` |
  | `source_status` | string | `"extracting"` on a fresh complete; `"ready"` on a sync-fallback path or replay after extraction finishes |
  | `services` | `[]Service` | services currently attached |
  | `message` | string | `"Source upload accepted, extraction in progress"` |
- **Errors**:
  - 400 sha256 mismatch (assembled file did not hash to declared value).
  - 409 missing parts → response includes `missing_parts: [int, ...]` so the client knows exactly which parts to re-PUT instead of restarting the whole upload.
  - 409 session not in `open` status (e.g. concurrent finalize, prior abort).
  - 503 `Upload queue full, please retry shortly` — extractor backpressure, retry after a few seconds.

> **Build/deploy gate.** Do not call `POST /deployments` until `GET /projects/:id` returns `source_status: "ready"`. The deployment-service refuses with 409 + `Retry-After: 5` when status is `extracting`, and 422 when status is `failed`. Poll `/projects/:id` every 2-5 s; typical extraction finishes in under a minute even for 1 GiB archives.

### Step 4-MP.4 - POST `/v1/upload/multipart/{upload_id}/abort`

Cancels an `open` session and unlinks the staging file. No-op-with-409 if the session is already `complete` (the assembled archive is now load-bearing for a project row and must not be deleted).

- **Headers**: `Idempotency-Key: <uuid>` required.
- **Body**: empty.
- **Response 200**: `{ "aborted": true }`.
- **Errors**: 404 missing session, 409 session is `complete` (preserved), 409 session is `finalizing` (concurrent complete in flight).

---

## Step 4.5 - POST `/v1/upload/update-source` (project-service)
Bind the parked archive to an existing project. Copies the temp file into the OpenDeploy project-source storage path, **enqueues async extraction**, and sets `project.original_file_path` + `project.source_status='extracting'`. The worker flips `source_path` + `source_status='ready'` once the ZIP is unpacked. Handler: `project-service/internal/handlers/upload.go` (`UpdateProjectSource`).

Use this only when the archive is `<= 100 MiB`. Larger archives → Step 4-MP.

This is **required for every ZIP-based deploy**. It only binds source. It is not a planning step; deployment planning remains local and agent-led.

- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `project_id` | uuid | yes | existing project from Step 3.1 |
  | `temp_file_path` | string | yes | value returned by Step 4 - backend `os.Stat`s this path, so it must still exist |
  | `analysis` | object | optional | local agent/CLI plan metadata only. Do not rely on this field for planning. Unknown fields are ignored. |
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `project_id` | uuid | echo |
  | `source_path` | string | **empty when ZIP extraction is async**; populated on the project row by the worker. Only non-empty in the legacy non-ZIP path or in the rare sync-fallback when `SourceExtractor` is not initialized. |
  | `source_status` | string | `"extracting"` on a fresh ZIP commit; `"ready"` for non-ZIP uploads or replays. Build/deploy MUST poll `GET /projects/:id` until this is `"ready"`. |
  | `services` | `[]Service` | services currently attached to the project |
  | `message` | string | `"Source upload accepted, extraction in progress"` for the async path; `"Project source updated successfully"` for the sync path; `"Project source already up to date"` when the temp file is expired but the project still has a valid `source_path` |
- **Errors**:
  - 400 `{"error":"Uploaded file not found or expired..."}` - temp file cleaned up before this call. Re-upload and retry.
  - 403 ownership - wrong user.
  - 404 - wrong project id.
  - 500 - filesystem write failed.
  - 503 `Upload queue full, please retry shortly` - extractor backpressure, retry after a few seconds.

> **Build/deploy gate.** Do not call `POST /deployments` until `GET /projects/:id` returns `source_status: "ready"`. The deployment-service refuses with 409 + `Retry-After: 5` while status is `extracting`, and 422 with `extraction_error` set when status is `failed` (re-upload is the only path forward). Polling cadence: every 2-5 s. Typical extraction finishes within a minute even on multi-thousand-file archives.

---

## Step 5 - PUT `/v1/projects/:id/services/:service_id/env` (project-service)
Optional: override / rotate runtime variables after the service is created. **Full replace** - missing keys get removed.

- **Path params**: `id` = `PROJECT_ID`, `service_id` = `SERVICE_ID`.
- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `variables` | map[string]string | yes | replaces all runtime vars for this service |
- **Server limits** (400 on violation): key <= 128 chars, value <= 32 KiB.
- **Response 200**: `{ "service_id": uuid, "variables": [...], "count": int }`.

> **Encryption-at-rest:** every value in `variables` is encrypted server-side before the row is written (`service_variables.value` is ciphertext, `is_encrypted=true`). Skill sends **plaintext** — do not pre-encrypt. The matching `GET` decrypts and returns plaintext, so the GET-modify-PUT pattern works unchanged.

> To rotate one value, first `GET /projects/:id/services/:sid/env` (returns the decrypted map) and PUT the merged map. Never log the GET response body wholesale — it contains decrypted secrets.

---

## Step 6 - no-op (resources handled inline)

Resources are set **only at Step 3.3** (`cpu_request / cpu_limit / memory_request / memory_limit` in the `POST /v1/projects/:id/services` body, K8s strings - `500m`, `2`, `1Gi`, `4Gi`). The deployment handler reads them off the Service row for each build.

> **Do NOT pass `resources:{...}` in the Step 7 body.** Earlier versions of this schema suggested re-asserting resources there; that re-assertion 400s with `json: cannot unmarshal string into Go struct field ResourceLimits.resources.cpu_limit of type float64` because the deployment-service `ResourceLimits` struct expects **numeric cores/GiB**, not K8s strings. Either leave the block off entirely (recommended, Service row is authoritative) or, if you must override per-deploy, send numeric values (e.g. `cpu_limit: 2.0`, `memory_limit: 4`).

> **Do not call `PUT /v1/projects/:id/resources`.** The handler (`UpdateProjectResources`) is registered on deployment-service (`deployment-service/internal/routes/routes.go:85`) but **not** proxied by the gateway (`gateway/internal/routes/routes.go` has no matching route). Attempting returns 404.

### Alternative: change resources on an existing running service

If you later need to adjust resources without redeploying:

#### PUT `/v1/services/:id` (project-service, gateway-exposed)
- **Path params**: `id` = `SERVICE_ID`.
- **Body** (partial update; only the fields below relevant here - see `UpdateServiceRequest` for full set):
  | field | type | note |
  |---|---|---|
  | `cpu_request` | string | K8s cpu, e.g. `500m` |
  | `cpu_limit` | string | e.g. `2` |
  | `memory_request` | string | e.g. `1Gi` |
  | `memory_limit` | string | e.g. `4Gi` |
- **Response 200**: updated `Service` object.
- Per-service only - loop over `SERVICE_ID`s if you want to touch them all.

---

## Step 6.5 - Persistent volumes (project-service)

Manage volumes after a service is created. Initial volumes can be set
inline at Step 3.3 via the `volumes` array; these endpoints handle
post-create mutations and the orphan/restore lifecycle.

### POST `/v1/services/:id/volumes`
Add a single volume to an existing service. **Destructive** when the
service has zero volumes today: the API deletes the existing Deployment
and creates a StatefulSet, with ~30 seconds of downtime. Subsequent
volumes on a service that already has at least one are non-destructive
patches.

- **Path params**: `id` = `SERVICE_ID`.
- **Body**: one volume object (same sub-schema as the Step 3.3 `volumes` entry).
- **Response 201**: `{ "volume_id": uuid, "deployment_id": uuid, "workload_conversion": bool }`.
  When `workload_conversion=true` the caller MUST poll the deployment
  status until `running` before considering the operation complete.
- **Errors**:
  - `403 quota_exceeded` - requested + existing volumes exceed plan storage cap. Body includes `requested`, `available`, `total`, `exceeded_resources`, and matching storage `available_addons` with quantity/price when configured.
  - `409 worker_capability_missing` - platform mid-rollout, retry in ~1 minute.
  - `409 conversion_in_progress` - service is already in a workload conversion.

### PATCH `/v1/volumes/:id/size`
Expand a volume. Shrink is rejected.
- **Body**: `{ "size": "10Gi" }`.
- **Response 200**: updated volume object with new `size`.
- **Errors**:
  - `400 cannot_shrink` - new size is smaller than current.
  - `403 quota_exceeded`.

### DELETE `/v1/volumes/:id`
Soft-delete (detach). The volume becomes `orphaned` and is retained for
7 days. Pass `?force=true` to skip the grace window and hard-delete
immediately (irreversible).
- **Response 200**: `{ "status": "orphaned" | "deleted", "orphaned_at": iso8601 | null, "expires_at": iso8601 | null }`.

### POST `/v1/volumes/:id/restore`
Move an orphaned volume back to its original service. Available only
within the 7-day retention window and only for the original owner.
- **Response 200**: updated volume object with `status=active`.
- **Errors**:
  - `410 orphan_expired` - retention window passed.
  - `403 owner_mismatch` - caller is not the original owner UID.

### GET `/v1/services/:id/volumes`
List volumes on a service.
- **Response 200**: `{ "volumes": [{ id, name, mount_path, size, status, k8s_pvc_name, orphaned_at, ... }] }`.

---

## Step 7 - POST `/v1/deployments` (deployment-service)
Trigger build + deploy for one service. Requires subscription + quota (gateway returns 403 otherwise).

- **Body** (skill-relevant fields only - full set in `CreateDeploymentRequest`):
  | field | type | required | note |
  |---|---|---|---|
  | `project_id` | uuid | yes | |
  | `service_id` | uuid | yes | the service to deploy |
  | `environment` | string | internal | omit from agent commands; CLI `0.1.14+` fills the single internal target |
  | `source` | string | yes | `git` (Step 4.b) or `zip` (Step 4.a) |
  | `temp_file_path` | string | yes | from Step 4 - stored on the deployment row for dependency-detection hints. **Does not feed the build.** The build activity reads the directory at `project.source_path` populated by Step 4.5 |
  | `branch` | string | optional | for `source=git` |
  | `resources` | object | **omit** | See Step 6. Sending K8s-string values 400s; Service row is authoritative. Only include if overriding per-deploy with numeric cores/GiB |
  | `strategy` | string | optional | deployment strategy; server default if omitted |
  | `version_type` | string | optional | `major` / `minor` / `patch` |
  | `description` | string | optional | |
  | `file_name` | string | optional | package filename for `upload` / `zip` source |
  | `source_path` | string | optional | extracted source path bound by upload/update-source |
  | `env_vars` | object | optional | leave empty - env was baked at Step 3.3 unless you did a Step 5 override |
  | `dependencies` | []string | optional | dependency IDs this version binds to (from Step 3.2) |
  | `is_rollback` | bool | optional | leave false |
  | `use_github_token` | bool | optional | leave false |
- **Response 201/200**:
  | field | type | note |
  |---|---|---|
  | `id` | uuid | `DEPLOYMENT_ID` |
  | `status` | string | initial - usually `pending` or `analyzing` |
  | `runtime_variables` | string | JSON snapshot of runtime env at creation |
  | `build_variables` | string | JSON snapshot of build-time env at creation |
  | `source_code_info` | string | JSON snapshot of source/package metadata |
  | `project_id` / `service_id` | uuid | |
  | `environment` | string | internal platform value |
  | `created_at` | RFC3339 | |
- **400** missing `temp_file_path` or invalid strategy. **403** subscription / quota.

### Status + logs

#### GET `/v1/deployments/:id`
The canonical way to poll terminal state. Returns the full deployment record plus a `runtime_logs_query` hint.

- **Response 200** (skill-relevant fields only):
  | field | type | note |
  |---|---|---|
  | `id` | uuid | |
  | `status` | string | `pending`/`analyzing`/`pending_review`/`building`/`deploying`/`success`/`failed`/`cancelled`/`rolled_back` |
  | `progress` | int | 0-100; jumps to `10` right before the Temporal workflow starts |
  | `progress_percent` | int | canonical user-facing progress percentage; mirror of `progress` with terminal-state defaults |
  | `build_percent` | int | build-phase percentage for agent updates; 100 on success, otherwise follows `progress_percent` |
  | `message` / `error_msg` / `error_context` | string | populated on `failed` |
  | `temp_file_path` | string | echo from create |
  | `completed_at` | RFC3339 | set on terminal status |

> The `GET /v1/deployments/:id/status` alias **is listed in `Backend/API.md:62` as `.../:id/status` and `.../status/:id`** but the gateway does **not** register it - calls return 404 page-not-found. Always poll `GET /v1/deployments/:id` instead. The list form `GET /v1/deployments/?project_id=<pid>` returns the same record wrapped under `.data[]` if you need to correlate siblings.

#### GET `/v1/deployments/:id/logs?tail=N&since=RFC3339`
- **Response 200**: `{"deployment_id": uuid, "logs": [...] | null, "total": int}`. `logs` is `null` when the deployment failed in the pre-build synchronous path (Temporal workflow started but the per-service activity errored before writing any log) - that's the `progress=10` sub-2-second failure signature covered in `failure-playbook.md`.

#### GET `/v1/deployments/:id/logs/stream` (SSE)
Live deploy logs.

#### GET `/v1/deployments/:id/build-logs/stream` (WebSocket)
Live build logs from ClickHouse. Prefer this over SSE for builds > 5 min. "Task polling timeout" surfaced elsewhere is a frontend 5-min timeout - trust ClickHouse build_logs for real state.

---

## Step 8 - Domain binding (project-service)

### 8.1 GET `/v1/service-domains/check-subdomain/:subdomain`
- **Path params**: `subdomain` = the prefix only, not the full FQDN.
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `available` | bool | |
  | `reason` | string | filled when `available:false` - `"reserved"` or `"taken"` |
- **Reserved list** (hard-blocked server-side): common platform, auth, billing, DNS, system, observability, and deployment-stage labels such as `www`, `api`, `admin`, `dashboard`, `console`, `billing`, `login`, `auth`, `status`, `health`, `ingress`, `registry`, `monitor`, `grafana`, `root`, `ns1`, `ns2`, `mx`, plus related variants.

### 8.2 GET `/v1/service-domains?service_id=<uuid>`
List domains for a service.

- **Query params**:
  - `service_id` (uuid) - required filter.
  - `environment` - optional internal filter; omit from agent commands.
  - `type` (`auto`|`custom`) - optional.
- **Response 200**: array of `ServiceDomain`:
  | field | type | note |
  |---|---|---|
  | `id` | uuid | |
  | `service_id` | uuid | |
  | `project_id` | uuid | |
  | `domain` | string | full FQDN |
  | `environment` | string | internal platform value |
  | `type` | string | `auto` / `custom` |
  | `status` | string | `pending` / `active` / `verified` / `failed` |
  | `ssl_enabled` | bool | |
  | `is_primary` | bool | |

### 8.3 PUT `/v1/service-domains/:id/subdomain`
Rename the auto subdomain prefix.

- **Path params**: `id` = the auto domain's id from 8.2.
- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `subdomain` | string | yes | 2-32 chars, `[a-z0-9-]`, no leading/trailing hyphen |
- **Response 200**: updated `ServiceDomain` - new `domain` = `<subdomain>.opendeploy.site`.
- **Errors**: 400 invalid format; 409 collision; 403 not your service.
- **Caveat**: server-side handler is documented for auto-generated domains. If the auto domain row for the current backend target hasn't been written yet (can happen right after Step 7 completes), poll 8.2 for up to 30 s before 8.3.

> Note: `POST /v1/service-domains/:id/retry` is **custom-domain-only** (see Step 9.4). It rejects auto subdomains with 400. K8s ingress reconciliation after a rename is automatic — no explicit retry call needed.

---

## Step 9 - Custom domain binding (project-service, FlexCDN-backed)

User-owned hostnames (e.g. `app.example.com`) bound to a service via CNAME → FlexCDN edge → K8s ingress. Requires `IS_BOUND==1` per the skill's client-side gate (the backend itself does not currently 403 unbound credentials — see `service_domain.go:248`).

### 9.1 POST `/v1/service-domains/`

Create a custom domain row, provision FlexCDN resources (server, reverse proxy, ACME task, SSL cert + policy), and write the K8s ingress in the background.

- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `service_id` | uuid | yes | service to bind to |
  | `domain` | string | yes | FQDN, e.g. `app.example.com`. Must contain at least one dot, `[a-z0-9.-]+`, no public-suffix root |
  | `environment` | string | internal | omit from agent commands; CLI `0.1.14+` fills the single internal target |
  | `type` | string | yes | **must be `"custom"`** for this flow (omit or `"auto"` falls into the platform-managed path) |
  | `ssl_enabled` | bool | optional | defaults to `true` (ACME via FlexCDN) |
  | `cloudflare_enabled` | bool | optional | old non-FlexCDN path; leave unset |
  | `cloudflare_proxied` | bool | optional | old Cloudflare field; leave unset |
  | `is_primary` | bool | optional | sets the "default URL" flag |
- **Response 201**: full `ServiceDomain` row. Skill-relevant fields:
  | field | type | note |
  |---|---|---|
  | `id` | uuid | persist as `DOMAIN_ID` |
  | `domain` | string | echoes request |
  | `status` | string | `pending` (typical), `failed` (FlexCDN provisioning rolled back) |
  | `cname_target` | string | **the value the user must paste at their DNS provider**; on the FlexCDN path this is the platform-provided edge CNAME. Always read from the response, never hardcode or infer it from the auto-domain suffix |
  | `ssl_enabled` | bool | true after ACME issues; may be false on first response if ACME hasn't completed yet |
  | `flexcdn_enabled` / `flexcdn_server_id` / `flexcdn_ssl_cert_id` | bool / int64 | internal — useful for triage |
  | `error_msg` | string | populated when `status:"failed"` |
- **Errors**:
  - 400 `Invalid domain format` — bare TLD, missing dot, or invalid chars.
  - 403 quota body (`error:"Quota exceeded"`, `exceeded_resources`, `available_addons`) — user's plan caps custom domains. Ask with `Upgrade plan (Recommended)` first; if chosen, return `https://dashboard.opendeploy.dev/settings`.
  - 409 `domain is already wired to a service` — FQDN already attached. The previous binding must be deleted first; the skill cannot do this (`agent_delete_forbidden`) — hand the user the dashboard URL `${OPENDEPLOY_BASE_URL%/api}/projects/<owning_project_id>/domains` (or the generic `${OPENDEPLOY_BASE_URL%/api}/projects` if the owning project is unknown) and resume after they confirm.
  - 503 `CDN service temporarily unavailable` — FlexCDN unreachable; safe to retry once after ~30s.

### 9.2 GET `/v1/service-domains/:id`
Single-row read for polling status after create.

- **Response 200**: same `ServiceDomain` shape as 9.1's response. Watch `status` (`pending` → `verified` → `active`, or `failed`) and `error_msg`.

### 9.3 GET `/v1/dns/check?domain=<fqdn>&domain_type=custom`
Server-side DNS propagation probe across multiple resolvers (8.8.8.8, 1.1.1.1, 9.9.9.9, etc.). Authoritative for "did the user's CNAME land".

- **Query params**:
  - `domain` (string, required) — the FQDN being bound.
  - `domain_type` (string, optional) — set to `custom` to run the multi-resolver probe. `auto` short-circuits (always returns `propagated:true`) — don't use it for custom.
  - `expected_ip` (string, optional) — if set, propagation requires at least one resolver to return this IP.
- **Response 200**:
  | field | type | note |
  |---|---|---|
  | `domain` | string | echo |
  | `propagated` | bool | true when ≥75% of resolvers return a result |
  | `progress` | int | 0-100, percentage of resolvers that resolved |
  | `results` | []object | per-resolver: `server`, `region`, `propagated`, `resolved_ips`, `error` |
  | `http_reachable` | bool | server-side HEAD probe (true after edge accepts traffic) |
  | `checked_at` | RFC3339 | |
  | `expected_ips` | []string | echo of `expected_ip` if provided |

### 9.4 POST `/v1/service-domains/:id/retry`
Re-provision FlexCDN resources for a `failed` custom domain. Custom-only — auto rows return 400.

- **Body**: none (`{}` is fine).
- **Response 200**: updated `ServiceDomain` (status flips back to `pending`, `flexcdn_*` IDs are refreshed, `retry_count` is incremented).
- **Errors**:
  - 400 `Only failed domains can be retried` — caller polled wrong status.
  - 400 `Only custom domains can be retried` — auto row.
  - 400 `Retry window expired (30 minutes)` — past `failed_at + 30min`. The row must be deleted and recreated; skill cannot DELETE (`agent_delete_forbidden`). Follow `domain.md` Step 9.6's "I deleted it — recreate now" flow: surface the dashboard URL, wait for the user to delete the row, poll `GET /v1/service-domains/:id` for `404`, then re-`POST /v1/service-domains/`.
  - 503 `CDN service is not configured` — FlexCDN client missing on the backend.

### 9.5 PUT `/v1/service-domains/:id`
Update flags on an existing domain (auto or custom).

- **Body** (partial — send only the fields you want to change):
  | field | type | note |
  |---|---|---|
  | `service_id` | uuid | rebind to a different service in the same project |
  | `is_primary` | bool | mark as the canonical URL for the service |
  | `ssl_enabled` | bool | toggle SSL (custom domains usually keep this true) |
  | `cloudflare_enabled` | bool | old Cloudflare path |
  | `description` | string | free-form note |
- **Response 200**: updated `ServiceDomain`.

### 9.6 DELETE `/v1/service-domains/:id`
Hard-delete the domain row. FlexCDN resources (server, reverse proxy, ACME task, SSL cert + policy) are torn down synchronously **before** the row is removed; K8s ingress and Cloudflare DNS clean up async.

> **Dashboard-only.** The skill never calls this — `od_*` Bearer tokens get `403 agent_delete_forbidden` (see top-of-file gate). This entry is documented so the failure-playbook and `domain.md` can describe the dashboard handoff (`${OPENDEPLOY_BASE_URL%/api}/projects/<project_id>/domains`) and so the skill can read the post-delete state via `GET /v1/service-domains/:id` (expect `404` once the row is gone).

- **Response 200** (dashboard caller only): `{ "message": "Domain deleted successfully, resources are being cleaned up" }`.
- **Side effects** (dashboard caller only): `service_domains` unique constraint on `domain` is released, so the same FQDN can be re-added afterward. Custom-domain quota usage is decremented for the user.

### 9.7 POST `/v1/service-domains/:id/ssl`
Optional: upload a user-supplied SSL certificate instead of letting ACME issue one. Use for wildcard certs, EV certs, or domains where ACME HTTP-01 won't work. Only applies to FlexCDN-provisioned custom domains.

- **Body**:
  | field | type | required | note |
  |---|---|---|---|
  | `certificate` | string | yes | PEM-encoded cert chain (leaf + intermediates) |
  | `private_key` | string | yes | PEM-encoded private key |
- **Response 200**: updated `ServiceDomain` with `ssl_enabled:true` and FlexCDN cert ID populated.
- **Errors**: 400 invalid PEM; 400 `Domain is not provisioned on CDN yet` if FlexCDN didn't provision the row; 403 not your project.
- **Logging**: redact the body — `od_log` drops the `private_key` field at write time, but never echo the request body to stdout/stderr.
