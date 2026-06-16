# Deploy plan and second-pass review

`opendeploy deploy plan . --json` is the trust boundary before mutation. CLI
`0.1.19+` treats it as a local deployment auditor, not a thin framework guess.
It must be read-only: no credential creation, source upload, project creation,
dependency creation, service creation, or domain mutation.

The deploy is then executed as a dynamic step loop. The agent follows the
prescribed order, reads each CLI result, adjusts the plan when a recoverable
issue appears, and resumes from the same step. This is intentionally closer to
GStack's workflow style than to an opaque one-shot deploy API.

## Required shape

```json
{
  "status": "ready",
  "confidence": 0.87,
  "source": ".",
  "context": {
    "project_id": "",
    "service_id": "",
    "deployment_id": "",
    "source": "explicit_url|saved_context|new_project",
    "reason": ""
  },
  "complexity": {
    "level": 1,
    "class": "static|framework|dockerfile|stateful|multi_service|storage_decision_required|multi_protocol",
    "reason": ""
  },
  "services": [],
  "dependencies": [],
  "env_contract": {},
  "ai_config": {
    "requires_ai_api_key": false,
    "detected_providers": [],
    "api_key_vars": [],
    "base_url_vars": []
  },
  "ports": {},
  "package_manager": {
    "name": "",
    "version": "",
    "source": "package.json|dockerfile|unknown",
    "lockfile": "",
    "dependency_resolution": "locked|unlocked|unknown",
    "dockerfile_uses_unpinned_corepack": false
  },
  "evidence": [],
  "platform_fit": {
    "one_http_port": true,
    "requires_persistent_filesystem": false,
    "requires_object_storage": false,
    "unsupported_protocols": []
  },
  "archive_manifest": {
    "required_files": [],
    "included_overrides": [],
    "secret_like_entries": [],
    "excluded_required_files": [],
    "git_metadata": {
      "bind_mount": false,
      "references": [],
      "git_path_type": "missing|directory|file|other",
      "safe_build_vars": ["GIT_COMMIT", "APP_VERSION", "SOURCE_VERSION"]
    }
  },
  "mutations": [],
  "consents": [],
  "blocking_issues": [],
  "warnings": []
}
```

If a risk requires approval, return `status=consent_required` using
`cli-contract.md`.

## Checks

Plan must inspect:

- pasted dashboard URLs, saved `.opendeploy/project.json`, and duplicate-service risk
- framework and package manager
- framework config variants. Enumerate existing config files before reading
  them; do not hardcode `next.config.js` when the service may use
  `next.config.ts`, `.mjs`, or `.cjs`.
- primary runtime vs frontend asset tooling. Backend manifests and server entry
  points win over Vite/Webpack presence; Laravel/PHP with Vite assets is not a
  Vite static service.
- package-manager version, lockfile, and clean-build determinism
- Dockerfile package-manager commands (`corepack use`, `corepack prepare`,
  `pnpm`, `npm`, `yarn`, `bun`) and whether they match `package.json`
- monorepo root vs app subdirectory, including isolated sub-app vs shared
  workspace
- monorepo candidate scoring: app services, workers/cron, managed dependencies,
  prebuilt sidecars, and ignore-only dev/test/config packages
- compose service graph, not a raw compose runtime. Convert compose services
  into OpenDeploy app services, managed dependencies, env links, domains, and
  volumes.
- build command
- start command
- Dockerfile `EXPOSE`
- Dockerfile optional `ARG` defaults, especially no-default args expanded in
  `RUN` steps with `set -u` / nounset
- compose container port
- service `PORT` env
- runtime env keys
- build-time env keys
- AI Hub env needs. Carry `ai_config.requires_ai_api_key`,
  `detected_providers`, `api_key_vars`, and `base_url_vars` from analyzer output
  when present, then verify against source/package/env evidence. If AI keys are
  needed, ask whether to use OpenDeploy AI Hub before asking the user to provide
  provider keys. See `references/ai-hub.md`.
- runtime/build env separation: runtime keys are for the running process, build
  keys are for image/build commands. The two maps must not be identical unless
  source evidence proves every key is consumed in both phases, which is rare.
  Overlapping keys need an explicit reason in the plan.
- startup-critical env keys: values read during module import, framework
  bootstrap, top-level provider/client construction, auth strategy
  registration, method calls on env values without fallback, or URL
  construction. These are required for boot even when the feature looks
  optional.
- app-generated credentials that can be safely created locally, such as
  basic-auth users, app secret keys, JWT/session secrets, encryption keys, and
  admin bootstrap secrets
- DB/cache type
- DB/cache env aliases
- service count vs guest cap
- multi-service resource budget: requested CPU/memory per service, managed
  dependency count, and rollout buffer for replacement deployments
- source archive excludes
- source archive smart-packaging decisions (`required_files`,
  `included_overrides`, `secret_like_entries`, `git_metadata`, warnings)
- source files that look generated but are required by the build
- Dockerfile/Makefile/package scripts that require Git metadata (`.git/`,
  `git describe`, `git rev-parse`, BuildKit `.git` bind mounts)
- Dockerfile `ARG` declarations with no default that are expanded as `${ARG}`
  under `set -u` / nounset. Optional build args should have safe Dockerfile
  defaults before cloud mutation; empty build variables may be dropped before
  BuildKit.
- regional package-mirror references (CN-region npm/yarn/pip/maven/apt/apk/go/
  rubygems/cargo/composer hosts) that the target build region cannot reach.
  See `references/analyze-local.md` section 4.6 for the host list, file scan,
  proposed mutation shape, and apply commands. Detection is generic across
  ecosystems; do not encode a per-framework allowlist. When found, surface a
  single `regional_mirror_strip` consent before upload; recommended option is
  `apply`. Never silently rewrite the user's source.
- dependency env outputs whose secret values are placeholders such as
  `changeme`, `password`, or `secret`
- whether placeholder dependency keys are actually consumed by the app or are
  unused compatibility aliases
- persistent data requirements
- installer/admin bootstrap requirements
- migration/bootstrap requirements (`manage.py migrate`, Rails migrations,
  Laravel migrations, Prisma/Drizzle/Alembic migrations, collectstatic/setup
  commands) and whether they run before first traffic
- late-bound public URL / domain env
- namespace/DNS sanity

For app-generated credentials, prefer generating strong local values and
continuing when deploy/env consent is already granted. Stop only for external
user-owned credentials such as provider API keys, OAuth client secrets, SMTP
passwords, or storage access keys.

## Evidence and context rules

Use explicit target context. Before any mutation, write a small context table
in the plan:

- source path or Git URL
- project ID and service ID, if known
- whether IDs came from a pasted dashboard URL, saved context, or a new-project
  decision
- selected service root and deploy mode

Pasted dashboard URLs always win over saved local context. For redeploys, pass
the existing project/service IDs; omitting a service ID can create duplicate
services on platforms with "deploy creates service" semantics, so treat missing
service ID as a blocking ambiguity unless the user asked for a new service.

Every non-trivial plan decision needs evidence. Examples:

- port `3000` because `Dockerfile` has `EXPOSE 22 3000` and `3000` is the HTTP
  listener while `22` is SSH
- managed Postgres because `docker-compose.yml` has a `postgres` service and
  the app references `DATABASE_URL`
- Dockerfile mode because a source-root `Dockerfile` exists
- pinned `pnpm@9.7.1` because `package.json.packageManager` declares it and
  the Dockerfile otherwise runs unpinned Corepack
- `dependency_resolution_not_locked` because a Node app has no lockfile and a
  clean cloud install may resolve newer packages than local `node_modules`
- storage decision required because `VOLUME ["/data"]` is declared and runtime
  files need either object-storage/media env or a clear local-file behavior note

For monorepos and multi-service apps, add a compact service graph:

| Service | Kind | Source | Build | Start | Port | Dependencies |
|---|---|---|---|---|---|---|

Also add a compact rollout order and identity budget before mutation:

| Order | Service | Why now | Needs URL from | Patches after live URL | Memory |
|---|---|---|---|---|---|

Rules:

- Isolated sub-apps can use the app directory as source/root.
- Shared workspaces should upload from repo root and use filtered commands
  (`pnpm --filter`, `npm --workspace`, `yarn workspace`, `turbo --filter`,
  `nx run`) so shared packages remain available.
- JavaScript workspace services should be staged from package-level evidence:
  generate a service name from the package/directory, use package-specific
  build/start commands, ignore config/test packages, and record which package
  path would be the watch path.
- One public HTTP entrypoint by default. Workers, queues, schedulers, and cron
  services stay internal unless the user asks for multiple public services.
- Deploy one service at a time until the core public route is healthy. Prefer
  dependencies -> API/web -> websocket/realtime -> frontend/dashboard ->
  workers/cron. Parallel deployment is allowed only when the resource budget and
  service graph prove that all rollout buffers fit.
- Same Dockerfile/image with different start commands or mode env is valid when
  the repo supports web/worker variants.
- For wrapper-image services, use a tiny included upload source and one
  explicit Dockerfile per service. Store generated secret/body files outside the
  upload root, then run the archive manifest check before upload.
- For URL-shaped env consumed at startup, plan a real service URL, valid boot
  placeholder, or an approved omission before first deploy. Empty URL strings
  are unsafe when source evidence shows startup validators or `new URL(...)`.
- Late-bound service URLs require a planned patch plus new deployment for each
  consumer. Do not count a restart as applying app-visible env changes.
- Compose files are input evidence, not a deployment unit. Source-built app
  entries become services; `postgres`/`mysql`/`mongo`/`redis`/`valkey` become
  managed dependencies when supported; image-only sidecars are either managed
  dependencies, explicit support gaps, or prebuilt-image services when the
  platform exposes that path.
- Do not ask the user to choose every service. Pick the highest-confidence
  OpenDeploy plan, then ask only for equally plausible public entrypoints,
  external secrets, storage strategy, paid/quota changes, or source edits.

If a decision has no file/CLI/log evidence, lower confidence or ask before
mutation. Do not use a deploy attempt as the evidence-gathering mechanism. For
mixed frontend/backend repos, the plan should identify the primary runtime from
backend evidence before frontend tooling; Vite/Webpack presence is not enough
to classify the whole app as static.
If the plan corrects the CLI's first guess, phrase it as a plan-review
correction, not a platform blocker: "Runtime is Laravel/PHP; Vite is the asset
builder" is better than "the auto-plan is critically wrong."

If `archive_manifest.git_metadata.bind_mount == true`, treat it as a blocking
pre-mutation issue. Archives exclude `.git` by default, and Claude/Codex
worktrees often store `.git` as a pointer file rather than a portable directory.
Prefer passing build variables derived locally (`GIT_COMMIT`, `APP_VERSION`,
`SOURCE_VERSION`) or ask before patching source. Do not upload `.git` by
default.

## Complexity classes

Use a coarse complexity class to decide how much review is required:

| Level | Class | Meaning | Required behavior |
|---|---|---|---|
| 1 | `static` | one static site / SPA, no runtime DB | verify build output, start/serve port, source archive |
| 2 | `framework` | one server app, no managed dependency | verify start command, port, runtime env |
| 3 | `dockerfile` | app has an existing Dockerfile | inspect `EXPOSE`, `CMD`/`ENTRYPOINT`, `VOLUME`, user, build args |
| 4 | `stateful` | app + DB/cache | create dependency first, wait ready, map env aliases, read back env |
| 5 | `multi_service` | multiple app services or workers | require explicit service split, public entrypoint, internal env wiring |
| 6 | `storage_decision_required` | app writes durable runtime files, uploads, backups, or media | ask for OpenDeploy volume, object-storage/media env, local-file behavior, or review details before mutation |
| 7 | `multi_protocol` | app needs SSH/SMTP/raw TCP or multiple public ports | expose only one HTTP port; surface unsupported protocols before mutation |

Higher classes do not mean "do not deploy"; they mean the agent must surface the
platform fit and avoid silent retries.

## Second-pass review

Do not tell the user that an "outside voice" found issues unless an independent
agent or reviewer actually performed this pass. In normal single-agent runs,
call it a self-review or plan review.

`opendeploy deploy plan . --review --json` should challenge:

- DB type missed or over-detected
- `DATABASE_URL` / `REDIS_URL` not going to the correct service
- user `.env` empty value overriding generated DB URL
- `.env.example` mistaken for real env
- existing root Dockerfile ignored, or missing Dockerfile treated as something
  the agent should create
- backend app classified as a frontend asset builder because Vite/Webpack files
  exist
- monorepo root wrong
- worker/web split wrong
- shared workspace deployed from a too-narrow subdirectory, hiding local
  `packages/*` or workspace dependencies
- worker/cron service accidentally given a public HTTP route
- port/start mismatch
- multiple exposed ports where the selected port is not the HTTP listener
- secondary protocols (SSH, SMTP, raw TCP, database ports) that OpenDeploy will
  not expose through the HTTP ingress
- durable data paths declared through Dockerfile `VOLUME`, compose volumes,
  app docs, or env keys without a chosen storage strategy (object-storage env,
  persistent volume via `opendeploy-volume`, or explicit ephemeral acceptance)
- installer-lock/setup-complete flags without an admin/bootstrap plan
- DB-backed framework with no migration plan before first traffic
- late-bound URL/domain env that should be set after the live URL exists
- source archive excludes that drop required non-secret source files, for
  example a project-owned `build/` directory or a credential-free `.npmrc`
- `docker-compose depends_on` not mapped to dependency
- dependency hostname namespace suffix mismatch
- regional package-mirror references left in source (CN-region npm/pip/maven/
  apt/go/etc. hosts) that the target build region cannot reach. If
  `analysis.regional_mirrors.detected` is `true`, the plan must carry a
  `regional_mirror_strip` mutation and consent. Otherwise the build will
  time out on `yarn install` / `pip install` / `apk add` / `apt-get` with
  `ESOCKETTIMEDOUT` or repeated `network connection. Retrying...`.

Proceed only when `blocking_issues` is empty.

Storage rule: if the app needs persistent runtime files, present a storage
decision before mutation. Available options on the OpenDeploy path:

- **Attach OpenDeploy volume** — add a per-service persistent disk
  (node-local, single-attach RWO) and mount it at the app's durable path.
  Recommended when the app writes local uploads, backups, media, SQLite files,
  file queues, on-disk repo storage, indexes, or other durable data to a fixed
  filesystem path. This stays the recommended option for demos/templates too
  when users can create new uploads/media or other local files; do not label
  ephemeral storage "Recommended for demo" in that case. Never auto-attach:
  surface this option and let the user pick it. Routing depends on whether the
  service exists yet:
  - **New service (during first deploy):** include the `volumes` array
    inline in `service.json` on the `services create` step (see
    `references/api-schemas.md` Step 3.3 `volumes` sub-schema). The service
    spawns as a StatefulSet from the start — no downtime, no conversion.
    Do **not** route to `opendeploy-volume` here; that would create the
    service as a Deployment first and then force the destructive conversion
    that the inline path was designed to avoid.
  - **Existing service (redeploy or post-deploy storage add):** route to
    `opendeploy-volume`. Adding the first volume to an existing service
    triggers a destructive Deployment→StatefulSet conversion with ~30s
    downtime; subsequent volume add/resize/etc. are non-destructive.
    `opendeploy-volume` carries the workload-conversion confirmation.
- **Configure storage first** — set the app's supported object-storage/media env
  (S3/R2/Spaces/etc.). Use this when the app is already designed for external
  object storage and only needs those env values. This means the agent must
  have the storage env source before mutation: either structured secret input
  from the user or a local 0600 env/body file path. Do not create
  project/dependency/service resources first and then ask the user to run CLI
  snippets with storage credentials.
- **Continue with ephemeral local files** — deploy now without persistence;
  file-backed paths are lost on restart/redeploy/reschedule. Allowed only
  after the user explicitly accepts data loss for those paths. This option is
  never the recommended default for apps with uploads/media/user-created files.
- **Pause before mutation** or engage OpenDeploy support through the user's
  private Discord channel (`opendeploy-oncall`).

Do not call the deploy a preview and do not suggest a competing platform unless
the user explicitly asks for alternatives.

Port rule: OpenDeploy first deploy exposes one HTTP listener. Ignore `EXPOSE 22`
and similar non-HTTP ports when choosing the web port unless the user explicitly
asked for that protocol and the platform supports it.

Retry rule: one retry is allowed after a concrete fix with read-back evidence
(for example, service port patched and verified). Do not run multiple redeploys
to discover the root cause. If logs, archive manifest, or service read-back do
not explain the failure, stop and report the missing platform signal instead of
guessing.

## DB/env ordering

Hard order:

```text
create project
create DB/cache dependencies
wait dependencies running
fetch dependency env_vars
assert consumed dependency secrets are non-placeholder
synthesize env aliases
merge service env
create service
read back service env
assert required DB env exists
assert runtime/build env maps are not accidentally mirrored
apply approved source mutations (e.g. regional_mirror_strip) — see analyze-local.md §4.6
verify source archive manifest
upload source
create deployment
wait deployment active
patch late-bound URL env and create a new deployment if planned/approved
resolve auto domain
report bind-first handoff for unbound guest projects, or live URL plus dashboard URL for bound projects
```

If startup-critical env remains unresolved before service creation, resolve it
in this order: real local env file with upload consent, managed dependency env,
generated app secret, manual user value, or user-approved boot-safe placeholder
for integrations that are not needed for the first smoke test. Do not create a
deployment just to discover missing env one crash at a time.

AI Hub keys have a dedicated first-choice path. If `ai_config` or source review
detects AI provider key vars, ask whether to use OpenDeploy AI Hub. For that
choice, put `{{OPENDEPLOY_AI_API_KEY}}` only in `runtime_variables` for the
detected AI key vars and `https://api.opendeploy.dev/v1` only in
`runtime_variables` for paired base URL vars. The placeholder string
`OPENDEPLOY_AI_API_KEY` is the literal backend-canonical name — keep it as-is
even though the product is "AI Hub"; the backend hardcodes that token for
expansion. Do not put the AI Hub placeholder in `build_variables`; if the app
performs AI provider calls during build, ask for user-provided build-time
values or patch the build to defer provider access to runtime.

When writing service or deployment bodies, carry the two maps through unchanged:
`runtime_variables` stays runtime-only and `build_variables` stays build-only.
Do not use "same object for both" as a convenience fallback. Deployment history
should show the exact env split used for that version.

Every service body must also include an explicit `type`: `web` for the public
HTTP entrypoint, `worker` for background workers, `cron` for scheduled work, or
`static` only for static-site service mode. Validate this locally before
calling `services create`; a missing `type` is a schema error, not a deploy
failure.

Current executable resource commands should mirror this order. Use
`references/cli.md` for the exact command forms. The `deploy step` dispatcher is
allowed only when the installed CLI returns executable `next_action` commands;
fall back to resource commands on `status=not_implemented`.

Placeholder dependency secrets are evaluated against the env contract, not as a
blanket stop. If the app consumes `DATABASE_URL` and that URL is real, unused
alias placeholders such as `DB_PASSWORD` or `PGPASSWORD` should be reported as a
key-only warning and ignored. Stop only when a consumed key, generated
connection URL, or synthesized consumed alias would carry the placeholder.

```bash
opendeploy projects create ... --json
opendeploy dependencies create ... --json
opendeploy dependencies status <project-id> --json
opendeploy services create <project-id> --body service.json --json
# require verification.ok before upload/deployment
opendeploy upload update-source <project-id> <source-path> --project-name <name> --region-id <region-id> --json
opendeploy deployments create --project <project-id> --service <service-id> --json
opendeploy deployments get <deployment-id> --json
opendeploy domains list --service <service-id> --type auto --json
opendeploy deploy report <deployment-id> --json
```

Merge order:

```text
local plan defaults
+ user real non-empty env values
+ DB generated env
+ user-approved OpenDeploy AI Hub runtime placeholders/base URLs
+ explicit user-approved conflict override
```

Rules:

- Empty user env cannot override DB env.
- Placeholder values cannot override DB env.
- `.env.example` cannot override managed dependency env.
- OpenDeploy AI Hub placeholders may override empty/example AI provider key
  values only after the user chose `Use OpenDeploy AI Hub`.
- If real user `DATABASE_URL` conflicts with managed DB URL, ask whether to
  use managed DB, use external DB, or cancel and edit env.
