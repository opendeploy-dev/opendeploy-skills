---
name: opendeploy-monorepo
version: "0.0.20"
description: Plan OpenDeploy service splits for monorepos, workspaces, docker-compose apps, web+worker apps, cron jobs, and multi-service projects. Use when the user says monorepo, workspace, pnpm workspace, turborepo, nx, multiple apps, multiple services, worker, queue, cron, docker-compose, compose, Procfile, web/API split, root directory, app directory, service split, or when OpenDeploy analysis detects more than one candidate service.
user-invokable: true
---

# OpenDeploy Monorepo / Multi-Service

This skill turns a repo with multiple deployable pieces into one OpenDeploy
project plan. It is normally invoked internally by `/opendeploy`; users do not
need to switch commands.

## Preflight

If invoked directly, run the normal OpenDeploy gate first:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy update check --json
opendeploy preflight . --json
opendeploy deploy plan . --review --json
```

Use the global `opendeploy` binary only. Do not use `npx`.

## Core Rule

Build a service graph, not a list of guesses.

For every candidate, decide:

- `service_kind`: `web`, `worker`, `cron`, `internal`, or managed dependency
- source root: repo root vs subdirectory
- build command and start command
- public HTTP port, or no public port for workers
- dependencies and env aliases
- persistence needs: OpenDeploy volume, object storage env, managed DB/cache

Do not stop just because a repo is a monorepo or has a compose file. Stop only
when the public entrypoint, required user-owned secrets, destructive storage
choice, or source edit cannot be inferred safely.

## Monorepo Shape

Use this source-shape distinction:

- **Isolated monorepo**: sub-apps do not share local packages. Deploy the app
  subdirectory as the service source/root, for example `apps/api`.
- **Shared workspace**: `pnpm-workspace.yaml`, `package.json#workspaces`,
  `turbo.json`, `nx.json`, or shared `packages/*` are needed at build/runtime.
  Keep the uploaded source at repo root and use filtered build/start commands,
  for example `pnpm --filter <pkg> build`, `pnpm --filter <pkg> start`, or
  `turbo run build --filter=<pkg>`. Do not set a narrow root that hides shared
  packages.

If unsure whether the workspace is shared, prefer repo-root source with filtered
commands. A too-narrow root is a common cause of missing package builds.

## Candidate Scoring

Score candidates before asking the user:

- Strong app signal: source-root or service-local Dockerfile, Procfile `web`,
  package scripts with `start`/`serve`, framework server entrypoint, compose
  `build:` plus an HTTP port, or docs naming the service as web/API/app.
- Worker signal: scripts/commands named `worker`, `queue`, `sidekiq`, `celery`,
  `scheduler`, `clock`, `beat`, `consumer`, or `cron`.
- Dependency signal: `postgres`, `mysql`, `mariadb`, `mongo`, `redis`,
  `valkey`, `meilisearch`, `elasticsearch`, `qdrant`, `minio`, `clickhouse`,
  `rabbitmq`, `kafka`, `mailpit`, `smtp`, or `storage` images/compose services.
- Ignore signal: config-only packages (`eslint`, `prettier`, `tsconfig`,
  `tailwind-config`), examples, docs, storybook, playground, benchmark, tests,
  seed/setup/init-only containers, `.devcontainer`, local-only proxy/shim
  packages that only forward to another app, and compose services gated by
  dev/test profiles.

Default to the highest-scoring public web/API service plus its required
workers and managed DB/cache. Ask only if two or more real public entrypoints
are equally plausible.

## Compose / Procfile Shape

For `docker-compose.y?(a)ml`:

- Build a service graph from compose; do not mirror every compose entry.
- Source-build app services become OpenDeploy services. A service is a good app
  candidate when it has `build:` or a repo-local Dockerfile/context plus a web,
  worker, or scheduler role.
- Ignore dev/test/tooling entries unless the user explicitly asks for them:
  `.devcontainer`, `devcontainer`, `test`, `e2e`, `mock`, `storybook`, `docs`,
  `benchmark`, `seed`, `setup`, one-shot init containers, and services enabled
  only by dev/test profiles.
- `image:`-only entries with no repo-local `build:` are prebuilt sidecars, not
  source-build services. Classify them as managed dependencies when OpenDeploy
  has a catalog item; otherwise surface the required image sidecar/support gap
  instead of trying to build it from the repo.
- When source evidence or upstream docs recommend a prebuilt app image, that is
  a valid OpenDeploy plan. If the current CLI cannot create image services
  directly, add a tiny wrapper Dockerfile (`FROM <image>`) per app service
  after source-edit approval. Place wrapper Dockerfiles at the upload root or a
  non-excluded deploy directory, not under `.opendeploy/`, `.claude/`,
  `.codex/`, or `.agents/`.
- Do not deploy Docker Compose as a runtime unit. Convert compose into
  OpenDeploy services, managed dependencies, env links, ports, domains, and
  volumes.
- `postgres`, `mysql`, `mongo`, `redis`, and `valkey` become managed
  OpenDeploy dependencies when supported by `opendeploy dependencies list`.
  `mariadb` may map to OpenDeploy's `mysql` dependency when the app is
  compatible, but do not present it to the user as "Managed MariaDB" unless the
  catalog actually exposes MariaDB.
- `depends_on` becomes dependency ordering plus env wiring; it does not prove
  the dependency is ready, so wait for dependency readiness before app service
  creation.
- `ports:` container side is the candidate OpenDeploy HTTP port.
- `volumes:` becomes a storage decision. Recommend OpenDeploy volume for local
  uploads/backups/media/SQLite/repo storage; object storage only when the app is
  already designed for S3/R2/Spaces env.
- If the chosen plan requires user-owned external storage credentials, collect
  the secret source before creating the project/dependencies/services. The agent
  runs the OpenDeploy env patch; the user should only provide values or a local
  0600 env/body file path, not a CLI command sequence to copy.

For `Procfile`:

- `web` is the public HTTP service.
- `worker`, `queue`, `sidekiq`, `celery`, `scheduler`, and `clock` are worker or
  cron services with no public HTTP domain unless the repo proves otherwise.

## Multi-Service Rules

Use this multi-service planning model:

- Pick one public entrypoint unless the user explicitly wants multiple public
  services/domains.
- Keep workers internal: no domain, no HTTP port requirement unless they expose
  health.
- If a frontend and API are both required, create both services and wire the
  frontend to the API URL after domains exist. Do not drop the frontend because
  the API has the clearer Dockerfile, and do not expose a worker as the public
  service.
- Create a deploy order before mutation. Normal order is managed dependencies,
  core API/web service, websocket/realtime services, frontend/dashboard, then
  workers/cron. Deploy one service at a time until the core public path is
  healthy, then add secondary services. Do not queue every service at once
  unless the quota check and service graph prove that a parallel rollout fits.
- Before creating services, write a compact resource budget: service count,
  requested memory/CPU per service, managed dependency count, and expected
  rollout buffer. Use the smallest known-good limits for workers, dashboards,
  websocket/realtime nodes, and wrapper-image services. If quota is tight, ask
  before a paid add-on or reduce the planned graph; do not discover quota by
  creating replacement services after failures.
- Same image, different mode is valid. Reuse one Dockerfile and set different
  `start_command` / env mode per service when the repo supports it.
- If multiple services use wrapper Dockerfiles or nested Dockerfiles, keep
  `source_path` at the uploaded root and set `dockerfile_path` to a file that
  exists inside that archive, such as `Dockerfile.web` and `Dockerfile.worker`.
  Run `opendeploy archive create . --json` and verify those Dockerfiles are
  included before upload. Do not put build-needed Dockerfiles in `.opendeploy/`;
  that directory is metadata and is excluded from source archives.
- Working directory matters. For shared workspaces, commands may need `cd` into
  the app package after installing from the repo root.
- For JavaScript workspaces, prefer package-manager filters over changing the
  archive root when local packages are imported:
  `pnpm --filter <pkg>`, `npm --workspace <pkg>`, `yarn workspace <pkg>`,
  `bun --filter <pkg>`, `turbo --filter=<pkg>`, or `nx run <project>:<target>`.
- Record watch-path style evidence in the plan even if OpenDeploy does not yet
  expose watch paths: which directories should trigger each service and which
  shared packages are required. This prevents agents from narrowing source too
  far on redeploy.
- For wrapper-image deploys, keep the upload source tiny but complete: one
  included Dockerfile per service plus any small health/start wrapper needed by
  those Dockerfiles. Keep generated service/dependency/deployment body files and
  secrets outside the upload directory. Run `opendeploy archive create . --json`
  from the wrapper source and verify no `.secrets`, `.env`, token, or private
  body file is included before upload.
- Plan migrations/init before first traffic. Prefer a one-off/release command
  if OpenDeploy exposes one; otherwise use a safe first-deploy start command or
  Dockerfile entrypoint after user approval.
- Migration commands must run in the command path the container actually uses.
  In auto-builder/package-manager mode, check whether the generated image runs
  the package `start` script; if so, patch that script after source-edit
  approval instead of assuming a service `start_command` override will win. In
  Dockerfile mode, prefer a Dockerfile `CMD`/entrypoint wrapper. Always prove
  the migration ran with the post-deploy smoke test before reporting success.
- Scan ORM/schema/config files for all DB URL aliases used by migrations, not
  only the app's main connection string. Examples include `DIRECT_URL`,
  `DATABASE_DIRECT_URL`, `MIGRATE_DATABASE_URL`, `SHADOW_DATABASE_URL`, and
  ORM-specific `directUrl` / `shadowDatabaseUrl` env references. If the app
  requires a direct migration URL and the managed DB URL is appropriate, set
  both before service creation.
- For DB/cache, create managed dependencies first, wait ready, fetch env, then
  create all app services with final runtime env.
- Before first deploy, resolve startup-critical URL-shaped env to either a real
  internal/public service URL, a syntactically valid boot placeholder, or an
  approved omission when source evidence shows the feature is disabled. Empty
  strings for values consumed by `new URL(...)`, schema validators, or startup
  config are not safe; catch them before a CrashLoop teaches the agent one key
  at a time.
- Late-bound service-to-service and public URL env must have an explicit pass:
  deploy the service that mints the needed URL, patch only the consumers that
  need that URL, then create a new deployment for those consumers. Do not rely
  on `services restart` to refresh app-visible env.
- For local persistent data, add the volume before first deploy when possible,
  then read back `opendeploy volumes list --service <id> --json` or the
  service `volumes` field. If no active volume appears, do not claim storage is
  attached and do not deploy data-loss-sensitive services until the storage
  decision is resolved.
- Workers usually do not listen on HTTP. Prefer service `type: worker` and
  `internal_only: true`. If the current platform still requires an HTTP
  readiness port for that worker, ask before adding a tiny health shim that
  starts the worker process and serves `200 ok` on the configured health port.
- Use the smallest known-good service-create body. When schema support is
  uncertain, create with stable core fields first, read back verification, then
  patch env/config. If a create times out or returns 5xx, read back by stable
  service name before retrying so one bad schema probe does not create
  duplicates.
- For each created service, read back and record a service identity matrix:
  service id, name, kind, `type`, public/internal flag, port, `source_path`,
  `dockerfile_path`, build/start command, expected image/Dockerfile, and whether
  the service is allowed to have a domain. If later logs show a different image,
  port, Dockerfile, or Kubernetes resource name under that deployment id, stop
  normal deploy loops and treat it as service mapping corruption.
- Save/record every service ID after creation. Redeploys must pass the existing
  service ID; omitting it can create duplicates.
- Recovery order for failed multi-service deploys is: inspect logs and service
  read-back, patch the same service config/env, try `deployments retry` when it
  can reuse the existing rollout slot, then create one fresh deployment for the
  same service. Do not create replacement services, stop unrelated healthy
  services, or use version rollback as a config repair unless read-back proves
  the original service row is gone and the user has approved the recovery plan.
- If the dependency catalog exposes a nearby but different engine version than
  the app docs name, allow the deploy only with a concise note and a smoke test
  plan. Do not casually say the version is "fine"; say what version is
  available and what runtime check will prove compatibility.

## User Questions

Ask only when the service graph cannot be proven from source evidence or when a
new consent gate appears. Use structured questions when available.
Every multi-option question must put `(Recommended)` in the recommended option
label itself and place that option first. Do not hide "recommended" only in the
description.

Good questions:

- "Which app in this monorepo should OpenDeploy deploy?"
- "Deploy web only, or web + worker?"
- "Attach OpenDeploy volume for uploads/backups?"
- "Add deployment files and continue?"

Do not ask the user to choose between technical variants when the source makes
the answer clear.

## Output Plan

Before mutation, keep a compact plan table:

| Service | Kind | Source | Build | Start | Port | Dependencies |
|---|---|---|---|---|---|---|

Then continue through the main `opendeploy` first-deploy flow.
