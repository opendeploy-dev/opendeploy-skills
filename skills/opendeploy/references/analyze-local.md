# Local source analysis - opendeploy Step 2

Reference for Step 2: materialize the source, detect services, emit a fixed-schema `analysis.json`. **All client-side.** Forbidden routes for agent-first deployment: `/upload/analyze-only`, `/upload/analyze-from-upload`, `/upload/analyze-env-vars`, `/create-from-analysis`, and any `/analyze*` endpoint.

Default future path is CLI-owned analysis:

```bash
opendeploy analyze . --json
opendeploy deploy plan . --review --json
```

The rules below are the contract the CLI and fallback agent analysis must
match.

JSON-mode discipline (Backend CLAUDE.md section 3): emit **exactly** the fields listed in section 3 below. If a field is not confidently knowable, use empty string / empty array - never fabricate.

## 0. Second-pass review

Before any cloud mutation, run a second-pass review over the generated
analysis/plan. If the agent environment explicitly allows parallel agents, ask
an independent agent for this pass; otherwise do the review yourself and record
the result in the deploy plan.

Do not call this "outside voice" in user-facing output unless an independent
agent or reviewer actually ran it. In normal single-agent flows, call it
"self-review" or "plan review".

Challenge these points:

- Context source: pasted dashboard URL IDs, saved `.opendeploy/project.json`,
  and user intent must not conflict. If redeploying an existing project, require
  an existing service ID or ask whether to create a new service.
- DB/cache type missed or over-detected.
- Frontend build tooling is mistaken for the deploy runtime. Backend evidence
  such as `composer.json` + `artisan`, `manage.py`, `go.mod`, `Gemfile`,
  Maven/Gradle files, Phoenix/Laravel/Rails/Django app files, or server
  Dockerfiles wins over Vite/Webpack/SPA evidence.
- `DATABASE_URL`, `REDIS_URL`, `MONGODB_URI`, `MYSQL_URL`, `POSTGRES_URL`, or
  host/user/password aliases are not assigned to the service that needs them.
- AI SDK/provider usage is present but `ai_config` is empty, or detected AI key
  vars are not assigned to the service that constructs the AI client. Capture
  `requires_ai_api_key`, `detected_providers`, `api_key_vars`, and
  `base_url_vars`, then ask about OpenDeploy AI Hub before asking for provider
  key values.
- `.env.example`, `.env.sample`, or placeholder values are treated as real
  user env.
- a root Dockerfile is present but the plan ignores it, or no Dockerfile exists
  and the plan assumes the agent should create one.
- Real user `.env` contains empty `DATABASE_URL` / `REDIS_URL` values that
  would override generated managed dependency env.
- Monorepo source root is too broad or points at the wrong app.
- Worker/web services are collapsed incorrectly.
- Auto-detection selected tooling/scaffolding directories (`.cursor`,
  `.devcontainer`, generators, CLIs, examples, docs, config packages) instead
  of the app service graph.
- A build-needed Dockerfile or wrapper Dockerfile is placed in a metadata
  directory that the smart archive excludes (`.opendeploy/`, `.claude/`,
  `.codex/`, `.agents/`).
- Docker `EXPOSE`, compose container port, framework default, and `PORT` env
  disagree.
- Dockerfile exposes multiple ports and the selected one is SSH/SMTP/raw TCP
  rather than the HTTP listener.
- Dockerfile `VOLUME`, compose `volumes:`, docs, or env keys indicate durable
  data paths but the platform has no persistent-volume primitive.
- Installer-lock/setup-complete flags appear without a plan to create the
  required admin/bootstrap state.
- DB-backed framework migrations are needed but not planned before first
  traffic. Check for `manage.py migrate`, Rails migrations, Laravel
  `php artisan migrate`, Prisma/Drizzle/Alembic commands, and similar.
- Migration commands reference DB env aliases that are missing from the
  service env plan. Check ORM/schema/config files, not just application
  runtime code.
- Late-bound URL/domain env (`APP_URL`, `BASE_URL`, `ROOT_URL`, `SITE_URL`,
  `PUBLIC_URL`, `CANONICAL_URL`, `SERVER_URL`, `WEB_URL`, or nested
  `__ROOT_URL` / `__DOMAIN` variants) is required but not planned.
- Source archive excludes would remove required non-secret source files, such
  as a project-owned `build/` directory or a credential-free `.npmrc`.
- `docker-compose depends_on` references DB/cache services that were not mapped
  to managed dependencies.
- A generated dependency hostname has a namespace suffix that does not match
  the project namespace expected for the app service.

If any item is blocking, stop before setup and ask or fix the plan. Do not
paper over uncertainty with a deploy-and-see loop.
Analyzer mistakes are not blocking by themselves. If direct source evidence
clearly corrects the service split, runtime, port, dependencies, or deploy mode,
rewrite the plan and continue. Use a structured question only when the fix needs
a new consent gate that is not already covered.

### Evidence ledger

For each service, record the evidence behind the selected deploy shape. Keep it
compact; the goal is to make the plan auditable, not verbose.

```json
{
  "service": "web",
  "decision": "port",
  "value": 3000,
  "evidence": "Dockerfile EXPOSE 22 3000; 22 is SSH, 3000 is HTTP web UI"
}
```

Required evidence categories:

- selected source root
- deploy mode (`autodetect`, existing `Dockerfile`, image, or other)
- selected HTTP port and ignored secondary ports
- build/start command or Dockerfile `CMD`/`ENTRYPOINT`
- dependency decision and env aliases
- AI Hub provider decision and env aliases (`api_key_vars`, `base_url_vars`)
- persistent filesystem/object-storage requirement
- required archive inclusions/exclusions
- late-bound public URL env keys

If evidence is missing for a category that affects first deploy success, ask
before mutation or mark it as a blocking issue.

### Complexity classification

Assign the same coarse class used by `deploy-plan.md`:

- `static`
- `framework`
- `dockerfile`
- `stateful`
- `multi_service`
- `storage_decision_required`
- `multi_protocol`

The class controls review depth. For example, a `dockerfile` app requires
Dockerfile inspection before service creation; a `stateful` app requires
dependency readiness plus env read-back; a `storage_decision_required` app
needs an explicit storage choice before mutation.

---

## 1. Materialize source to a local workdir

```bash
WORKDIR=$(mktemp -d)
case "$SOURCE_KIND" in
  git)    git clone --depth=1 ${GIT_BRANCH:+-b "$GIT_BRANCH"} "$GIT_URL" "$WORKDIR" ;;
  zip)    unzip -q "$ZIP_PATH" -d "$WORKDIR" ;;
  folder) WORKDIR="$SOURCE_PATH" ;;
esac
```

### Files to enumerate

One pass, do **not** recurse into `node_modules`, `.git`, `dist`, `target`, `vendor`, `__pycache__`, `.venv`.

```
package.json, pnpm-lock.yaml, package-lock.json, yarn.lock, bun.lock, bun.lockb
pnpm-workspace.yaml, turbo.json, lerna.json, nx.json, .npmrc
requirements.txt, pyproject.toml, Pipfile, setup.py
go.mod, Cargo.toml, pom.xml, build.gradle(.kts), composer.json, Gemfile
Dockerfile, */Dockerfile, */*/Dockerfile, docker-compose.y?(a)ml, Procfile
.env, .env.example, .env.sample, .env.template
next.config.{js,mjs,ts}, vite.config.*, nuxt.config.*, svelte.config.*,
  astro.config.*, remix.config.*, angular.json
README* (first 200 lines only)
```

**Config file variant rule.** Never read a hardcoded config filename until you
have enumerated the matching variants in that directory. For framework configs,
run `rg --files -g 'next.config.*' -g 'vite.config.*' -g 'nuxt.config.*' -g
'svelte.config.*' -g 'astro.config.*' -g 'remix.config.*'` (or the smallest
equivalent for the current service root), then read only the returned file(s).
If `next.config.js` is missing but `next.config.ts` / `.mjs` / `.cjs` exists,
read the existing variant and continue; do not stop or ask the user about the
missing guessed filename.

Real deploy env override files (`.env.local`, `.env.*.local`, and
environment-specific secret files) are not source analysis inputs. Top-level
`.env` is special: in PHP/Symfony/Laravel-style apps it may be committed,
non-secret source required by bootstrap, but OpenDeploy smart archives exclude
`.env` / `.env.*` for safety. Read `.env` only enough to classify whether it is
required safe defaults or secret config. Never copy real env values into
`analysis.json`. If it is required and safe, plan to recreate it in the
Dockerfile/entrypoint from literal non-secret defaults.

---

## 2. Multi-service detection

Pick the first matching rule:

1. **`docker-compose.y?ml` present** -> build a service graph; do not mirror
   every top-level `services:` entry as an OpenDeploy app service. Extract
   `image`, `build.context`, `ports`, `environment`, `depends_on`, `profiles`,
   `command`, and `restart`.
   - Repo-local `build:` services with a web/worker/scheduler role are app
     services.
   - Entries whose image/name matches `postgres | mysql | mariadb | mongo |
     redis | valkey | rabbitmq | clickhouse | elasticsearch | meilisearch |
     minio` are dependencies, not build services, when OpenDeploy exposes a
     compatible catalog item.
   - Ignore dev/test/tooling entries unless the user explicitly asks for them:
     `.devcontainer`, `devcontainer`, `test`, `e2e`, `mock`, `storybook`,
     `docs`, `benchmark`, `seed`, `setup`, one-shot init jobs, and services
     enabled only by dev/test profiles.
   - `image:`-only entries with no repo-local `build:` are prebuilt sidecars.
     Classify them as `prebuilt_image_sidecar`; do not attempt to build them
     from the source repo. If the sidecar is essential and OpenDeploy does not
     expose image-service support in the current CLI, surface that as a support
     gap before mutation.
2. **Procfile present** -> `web` is the public HTTP service; `worker`, `queue`,
   `sidekiq`, `celery`, `scheduler`, and `clock` are worker/cron services with
   no public domain unless source evidence proves they expose HTTP.
3. **Monorepo markers** (`pnpm-workspace.yaml`, `package.json#workspaces`,
   `turbo.json`, `lerna.json`, `nx.json`) OR multiple top-level `Dockerfile`s
   -> each workspace package that has its own `Dockerfile`, server entrypoint,
   or `scripts.start` is a service.
4. Otherwise -> single service named `$PROJECT_NAME`.

Classify the monorepo shape:

- **Isolated monorepo**: sub-apps do not import local workspace packages. Use
  the app subdirectory as the service source/root.
- **Shared workspace**: workspace packages under `packages/*`, local
  `workspace:*` dependencies, TypeScript path aliases, or Turborepo/Nx shared
  tasks are required. Upload from repo root and use filtered build/start
  commands (`pnpm --filter <pkg> build`, `turbo run build --filter=<pkg>`,
  etc.). Do not set a narrow root that hides shared packages.

For multi-service plans, emit one public entrypoint unless the user explicitly
asks for multiple public services/domains. Workers and cron services are
internal by default.

### Multi-service sanity checks

- Build a service graph, not one OpenDeploy service per directory.
- Ignore tooling packages even when they have `package.json`, `Dockerfile`, or
  scripts. App evidence must include a runtime role: public web/API, worker,
  scheduler, or explicitly requested internal service.
- Ignore local-only proxy/shim packages that listen on localhost and forward to
  another app; deploy the real upstream app service instead when source/docs
  identify it.
- Prebuilt app images are valid when repo docs/compose point to them. If image
  services are unavailable in the current CLI, create tiny wrapper Dockerfiles
  in an included path such as `Dockerfile.web` / `Dockerfile.worker`; do not
  put them under `.opendeploy/`.
- Worker-only services need an explicit readiness plan. If no HTTP listener is
  present and the platform requires one, ask before adding a minimal health
  shim. Do not expose a worker as the public service just to satisfy a port.
- Before upload, compare `archive_manifest.files` / `included_overrides` with
  each service's `dockerfile_path`, build context, and `COPY` sources. A
  service-specific Dockerfile that is absent from the archive is a blocker.

---

## 3. Per-service schema

Emit one object per service. For multi-service, wrap as `{"services":[...]}`. Save to `$WORKDIR/.opendeploy/analysis.json`.

```json
{
  "name": "api",
  "source_path": "./services/api",
  "language": "typescript",
  "language_version": "20",
  "framework": "nextjs",
  "build_tool": "pnpm",
  "package_manager": "pnpm",
  "package_manager_version": "9.7.1",
  "lockfile": "pnpm-lock.yaml",
  "dependency_resolution": "locked",
  "project_type": "web",
  "port": 3000,
  "entry_point": "src/server.ts",
  "output_directory": ".next",
  "scripts_build": "pnpm build",
  "scripts_start": "pnpm start",
  "database_type": "postgres",
  "dependencies": ["postgres", "redis"],
  "runtime_vars":  [{"name":"DATABASE_URL","required":true,"default":""}],
  "build_time_vars":[{"name":"NEXT_PUBLIC_API_URL","required":false,"default":""}],
  "ai_config": {
    "requires_ai_api_key": false,
    "detected_providers": [],
    "api_key_vars": [],
    "base_url_vars": []
  }
}
```

### Field-by-field rules

**`port`** - in priority order:
1. Dockerfile `EXPOSE <N>` -> the HTTP listener port. If there are multiple
   ports, prefer documented/common HTTP ports (`80`, `8080`, `3000`, `3001`,
   `4173`, `5000`, `8000`, `8081`) over SSH/SMTP/raw TCP ports (`22`, `2222`,
   `25`, `465`, `587`, database ports). If still ambiguous, ask.
2. compose `ports: ["host:container"]` -> `container`.
3. Framework default:
   - Next.js / Nuxt / Rails -> `3000`
   - Vite `preview` -> `4173`
   - Django -> `8000`
   - Flask -> `5000`
   - Spring Boot / Go `net/http` / Rust Actix -> `8080`
   - Laravel/PHP -> ask unless repo config, Dockerfile, compose, Procfile, or
     `APP_PORT` gives a clear HTTP listener. Do not use Vite preview `4173`
     for Laravel/PHP apps where Vite is only the asset bundler.
4. Ambiguous -> ask the user; do not guess.

OpenDeploy first deploy exposes one HTTP port. If the app also exposes SSH,
SMTP, metrics-only, database, or other raw TCP ports, surface the HTTP-ingress
behavior before mutation. Disable or leave secondary protocols inactive only
with user approval.

**`language` / `framework`** - derive from manifest, never from file extensions alone:
- `package.json.dependencies.next` -> `framework: nextjs`, `language: typescript` (if `tsconfig.json`) else `javascript`.
- `pyproject.toml.project.dependencies` containing `django` / `fastapi` / `flask` -> corresponding framework.
- `manage.py` at repo root -> `framework: django` even if `pyproject.toml` is
  missing or doesn't list `django` directly (Saleor-style layouts where Django
  is a transitive dependency).
- `go.mod` present -> `language: go`; framework from imports (e.g. `gin-gonic/gin` -> `gin`).
- `Cargo.toml` -> `language: rust`; framework from deps.
- `pom.xml` / `build.gradle*` -> `language: java`; framework from deps.
- `composer.json` plus `artisan` or `laravel/framework` -> `language: php`,
  `framework: laravel`. If `package.json` also has Vite, classify Vite as
  `build_tool`, not the runtime framework.
- `composer.json` with `symfony/*` -> `language: php`, `framework: symfony`.
- `Gemfile` plus `config/application.rb` containing `Rails::Application` ->
  `framework: rails`.
- Generic `composer.json` -> `language: php`; framework from Composer deps.

**Skill-side framework fallback.** If `opendeploy analyze --json` returns
`framework: ""` for a service, do not accept the empty value. Re-derive locally
using the rules above and record it in the deploy plan with
`framework_source: "skill_fallback"`. The local CLI auditor has been observed
returning empty `framework` for clearly-Django apps (settings module + manage.py
+ uvicorn ASGI Dockerfile), and a missing framework value cascades into missing
migration plans, missing default ports, and missing bootstrap warnings.

**`runtime_vars`** - union of:
- All keys in `.env.example` / `.env.sample` / `.env.template`.
- Grep hits for these patterns in source (just grep, do not parse AST):
  - JS/TS: `process.env.VAR_NAME`
  - Python: `os.getenv("NAME")`, `os.environ["NAME"]`, `os.environ.get("NAME")`
  - Go: `os.Getenv("NAME")`
  - Rust: `std::env::var("NAME")`, `env!("NAME")`
  - Ruby: `ENV["NAME"]`
  - PHP: `getenv("NAME")`, `$_ENV["NAME"]`
  - Shell: `$NAME` / `${NAME}` in `entrypoint.sh` / `docker-entrypoint.sh`
- `environment:` keys from each compose service.

Mark `required: true` only when:
- No default value in `.env.example` / `.env.sample` / `.env.template`, AND
- No fallback in code (e.g. `process.env.FOO || "bar"` -> `required: false`).

When unsure, `required: false` with `default: ""`.

Also classify env keys by deploy impact:

- `startup_critical`: referenced during module import, framework/bootstrap
  setup, top-level client/SDK construction, auth strategy registration, direct
  string method calls without fallback, or URL construction. These keys can
  crash the process before the HTTP server listens, so they must be resolved
  before the first deployment.
- `dependency_provided`: expected from managed DB/cache/storage dependencies.
- `generated_app_secret`: safe for the agent to generate locally with consent
  (session secret, encryption secret, basic-auth password, bootstrap password).
- `late_bound_url`: public URL/domain keys that need a temporary boot value or
  a planned post-success patch plus redeploy.
- `feature_optional`: only used inside route/job handlers or optional feature
  paths and safe to leave unset when source evidence shows the app guards that
  path.

For Node/JS services, startup-critical patterns include `process.env.KEY`
followed by a method call, `new URL(process.env.KEY)`, top-level provider
client constructors, and top-level auth strategy registration. Use the same
principle for other languages: env consumed while importing/configuring the app
is boot-critical; env consumed only when a feature is invoked is optional.

**`database_type`** - primary DB field; pick first non-cache match
for backwards compatibility:
1. Compose DB-image (`postgres` / `mysql` / `mariadb` -> `mysql` / `mongo` -> `mongodb` / `redis` / `valkey` -> `redis`).
2. Manifest deps:
   - Postgres: `pg`, `psycopg`, `psycopg2`, `psycopg2-binary`, `dj_database_url`,
     `sqlalchemy` with `postgres://`, `gorm.io/driver/postgres`, `lib/pq`,
     `tokio-postgres`, `sequelize` with `dialect:'postgres'`.
   - MySQL: `mysql2`, `pymysql`, `mysql-connector-python`, `gorm.io/driver/mysql`, `go-sql-driver/mysql`.
   - MongoDB: `mongoose`, `mongodb`, `pymongo`, `motor`, `mongo-driver`.
   - Redis: `redis` (npm/py), `ioredis`, `go-redis/redis`, `redis-rs`.
3. Empty string if none.

**Skill-side dependency fallback.** If `opendeploy analyze --json` returns
`dependencies: []` or `services[*].dependencies: []`, do not accept it for any
service whose framework is one of `django` / `rails` / `laravel` / `phoenix` /
`saleor` / `medusa`. Run a direct grep on the source for the dep markers above
plus `psycopg`, `redis`, `pymongo`, `pymysql`, `dj_database_url`,
`celery[broker=redis]`, and `CACHE_URL` / `REDIS_URL` references in settings.
For any hit, add a synthetic dependency entry to the deploy plan. If deploy
consent already covers managed dependencies, provision the managed dependency
before service creation and continue. Otherwise ask with a structured question
whose recommended option is to add the managed dependency first.
Deploying a Django/Rails-class app without a planned database is the single
most common preventable first-deploy failure.

**`build_time_vars`** - anything matching:
- Prefix `NEXT_PUBLIC_`, `VITE_`, `REACT_APP_`, `PUBLIC_`, `NUXT_PUBLIC_`, `EXPO_PUBLIC_`.
- Any var referenced in `scripts.build` / Dockerfile `ARG` / CI build command.

Only key names and requirement/default metadata come from `.env.example`,
`.env.sample`, or `.env.template`. Their values are never user-approved deploy
values and must not be copied into `build_variables` or `runtime_variables`.

Runtime/build split:

- `runtime_variables`: DB/cache/storage connection values, server-side
  secrets, app bootstrap credentials, `PORT`, runtime-only framework config,
  and late-bound public URL/domain keys.
- `build_variables`: Dockerfile `ARG` values, variables read by build scripts,
  and public client compile-time prefixes (`NEXT_PUBLIC_`, `VITE_`,
  `REACT_APP_`, `PUBLIC_`, `NUXT_PUBLIC_`, `EXPO_PUBLIC_`).
- Do not mirror all keys between the two maps. A key belongs in both only when
  repo evidence shows it is consumed by both a build step and the running
  process. Record that reason in the plan.
- Late-bound public client keys are often both build-time and runtime when the
  app embeds them into client bundles and also reads them on the server. For
  prefixes such as `NEXT_PUBLIC_`, `VITE_`, `REACT_APP_`, `PUBLIC_`,
  `NUXT_PUBLIC_`, or `EXPO_PUBLIC_`, record whether the key needs a post-domain
  rebuild, not just a runtime patch.
- Dependency env from managed DB/cache belongs in `runtime_variables` unless a
  build step explicitly connects to the dependency. Avoid build-time DB access
  by default because it makes clean builds depend on live runtime services.

**`ai_config`** - detect AI Hub / AI provider usage generically:

- Set `requires_ai_api_key: true` when AI SDK/provider dependencies, imports,
  env keys, or docs indicate the selected service needs an AI provider key for
  its deployed mode.
- `detected_providers` should use provider names from evidence, such as
  `openai`, `anthropic`, `gemini`, `google_ai`, `openrouter`, `groq`,
  `mistral`, `deepseek`, `together`, `perplexity`, `dashscope`, `qwen`,
  `volcengine`, `xai`, or the analyzer's provider strings.
- `api_key_vars` should include exact env key names such as `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`,
  or analyzer-provided names.
- `base_url_vars` should include paired base URL names such as
  `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `ANTHROPIC_BASE_URL`, or
  analyzer-provided names.
- Do not classify OAuth/payment/storage/SMTP secrets as AI merely because they
  end in `_TOKEN` or `_KEY`. Tie generic suffixes to provider/package evidence.
- If AI keys are build-time-only, add a `build_time_blocker` note in the deploy
  attempt record. Do not plan the OpenDeploy AI Hub placeholder for build vars.

If required env keys remain unresolved after managed dependency env and
generated app credentials, surface an env-source question before service
creation:

- local real `.env` exists -> recommend syncing that `.env`
- no local real `.env` -> recommend manually setting required vars
- optional-only keys -> allow continuing without them

If startup-critical provider credentials are missing and the app can still show
the core UI with fake provider values, ask before setting boot-safe
placeholders. Present this as a demo/startup aid, not as a real integration
setup, and report that the related feature will need real env values plus a new
deployment before it works.

Never recommend uploading `.env.example` values.

**`package_manager` / `lockfile` / `dependency_resolution`** - make clean cloud
builds deterministic before mutation:
- Read `package.json.packageManager` when present, for example
  `pnpm@9.7.1`, `npm@10.x`, `yarn@4.x`, or `bun@1.x`.
- Record the matching lockfile:
  `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `bun.lock`, or
  `bun.lockb`.
- If a Node/JS service has no lockfile, set
  `dependency_resolution: "unlocked"` and add a blocking review item before
  cloud mutation. Ask whether to generate a lockfile, proceed knowing a clean
  cloud build may resolve newer packages, or stop.
- Inspect Dockerfile package-manager commands. If the Dockerfile uses unpinned
  Corepack or latest-style commands such as `corepack use pnpm`,
  `corepack prepare pnpm@latest`, or a bare package-manager install while
  `package.json.packageManager` pins a version, ask before patching the
  Dockerfile to the pinned version. Prefer pinning the package manager to the
  repo declaration over upgrading the base image unless repo evidence requires
  a newer runtime.
- Treat package-manager mismatch as a pre-build issue, not a cloud retry
  issue. Do not wait for OpenDeploy to spend build minutes discovering that
  Node, Corepack, and the package-manager version are incompatible.

**`dependencies`** - list of all DB/cache types this service needs. Populate
with every unique detected type, not just `database_type`:
- `database_type` is non-empty, include it.
- Manifest deps or env keys identify additional engines, include each one.
- Multi-service compose has `depends_on` pointing at DB/cache services - include each referenced type.
- Compose contains DB/cache image services that are consumed by the app - include each type.

---

## 3.5 Deploy env collection - submit values to the platform API

This step is separate from source analysis. It exists so automatic deploys can
pick up local runtime/build configuration without uploading secret files.

Allowed behavior:

- Read real env files only to build deployment override maps.
- Submit the resulting key/value pairs through the CLI as `runtime_variables`
  / `build_variables` during service create, or via `opendeploy services env
  patch/reconcile` for env rotation.
- Keep local override files mode `0600`.
- Log and report only key names and counts, never values.

Forbidden behavior:

- Do not write real env values to `$WORKDIR/.opendeploy/analysis.json`.
- Do not include real env files in the source ZIP.
- Do not write real env values to `~/.opendeploy/logs/*`.
- Do not submit values from `.env.example`, `.env.sample`, or `.env.template`
  as runtime or build env. They are examples and schema hints only, even when
  the key has a public build prefix such as `VITE_*`.

Collect from these files when present, later files overriding earlier files:

```text
.env
.env.local
```

If the project has its own dotenv parser in its toolchain, prefer that parser.
Otherwise parse standard `KEY=VALUE` dotenv lines, ignoring blank lines,
comments, and malformed keys. Split variables with public build prefixes into
`user_build_overrides.json`; all others go to `user_overrides.json`. Do not
write the same flat env object to both files. When a key must be mixed, include
it in both files only after recording the build-time and runtime evidence.

If only example files contain a required public build-time key, ask the user for
real values or confirm that the app can build with the key absent. Never present
"upload `.env.example` values" as the recommended option.

```bash
umask 0077
: > user_overrides.json
: > user_build_overrides.json
chmod 600 user_overrides.json user_build_overrides.json

# The agent should materialize these JSON files as flat objects:
#   user_overrides.json        -> runtime env values submitted to the platform
#   user_build_overrides.json  -> build-time env values submitted to the platform
#
# Public build prefixes:
#   NEXT_PUBLIC_, VITE_, REACT_APP_, PUBLIC_, NUXT_PUBLIC_, EXPO_PUBLIC_
#
# Example shape only; never print values:
#   {"DATABASE_URL":"postgres://...", "SESSION_SECRET":"..."}
```

Delete the two override files after the deploy attempt completes, success or
failure. They are local transport files only.

---

## 4. Decision: does the project need a DB? (Step 2.5)

Create DB/cache dependencies in Step 3.2 if **any** of these hold:

- `analysis.database_type` in {`postgres`, `mysql`, `mongodb`, `redis`}.
- `analysis.dependencies[]` contains any of {`postgres`, `mysql`, `mongodb`, `redis`}.
- Any `runtime_vars[].name` matches `DATABASE_URL | MYSQL_* | POSTGRES_* | PG_* | REDIS_URL | MONGO*`.
- Section 2's compose parse found a DB-image service (`postgres|mysql|mariadb|mongo|redis|valkey|...`).

Mapping to `dependency_id` values for `POST /dependencies/create`:

| detected | `dependency_id` |
|---|---|
| postgres, postgresql | `postgres` |
| mysql, mariadb | `mysql` |
| mongodb | `mongodb` |
| redis, valkey | `redis` |

This mapping is internal planning only. User-facing choices must use engines
from `opendeploy dependencies list --json`. Do not show "Managed MariaDB" when
the planned OpenDeploy dependency is `mysql`; label it "Managed MySQL" and, if
helpful, say the app's MariaDB-compatible mode will use OpenDeploy MySQL. Do
not show "Managed SQLite"; SQLite is a local file and belongs in the
volume/storage decision. For SQLite, the user-facing option label should be
`Use SQLite on OpenDeploy volume`.

ClickHouse, RabbitMQ, Elasticsearch, Meilisearch, and MinIO may be detected
from compose or env names, but they are not OpenDeploy managed dependencies in
this skill version. Treat them as external services: surface a warning and ask
for user-provided env values rather than creating a managed dependency.

Create one dependency per unique detected type in Step 3.2 (no `service_id`);
reuse each dependency's `env_vars` in every consumer service's Step 3.3 body.
If multiple services share the same engine, create that engine once. If an app
needs both a SQL database and Redis, create both and merge both env maps.

If no signal triggers -> this is a no-op. Do NOT provision "just in case" - it burns region quota.

---

## 4.5 Persistent storage and bootstrap scan

Before packaging, scan for persistent filesystem expectations:

- Dockerfile `VOLUME`
- compose `volumes:`
- docs mentioning durable data directories
- env keys ending in `_DATA_DIR`, `_UPLOAD_DIR`, `_STORAGE_PATH`,
  `_MEDIA_ROOT`, `_REPO_ROOT`, or similar

If persistent storage is needed, pause and ask for the OpenDeploy storage
strategy. Available options:

- Attach an OpenDeploy volume via `opendeploy-volume` (recommended for local
  uploads, backups, media, SQLite, file queues, on-disk repo storage, indexes,
  or any app that writes durable data to a fixed filesystem path). For a
  **new service** in the current deploy, include `volumes` inline in
  `service.json` on `services create` when the CLI/backend supports it, then
  read back `volumes` or `opendeploy volumes list --service <id> --json`.
  If the active volume is not visible, add it through `opendeploy-volume`
  before first deploy. For an **existing service**, route to
  `opendeploy-volume`; the first volume on an existing service triggers a destructive
  Deployment→StatefulSet conversion with ~30s downtime.
- Configure the app's supported object-storage/media env when the app is
  already designed for external object storage and only needs S3/R2/Spaces env.
- Continue with ephemeral local files only after the user explicitly accepts
  data loss for those paths on restart/redeploy/reschedule. Do not recommend
  ephemeral just because the user says "demo" or "template" when the app accepts
  new uploads/media or writes user-created local files; recommend the OpenDeploy
  volume path first.
- Review details, or pause before mutation.

If the user chooses external object storage, collect the secret source before
any cloud resource creation. Use a structured secret question when available,
or ask for a local 0600 env/body file path. The agent should run the
OpenDeploy `services env patch --body ... --confirm-env-upload` commands after
services exist; do not ask the user to paste or execute CLI command blocks as
the normal path.

Never auto-attach a volume — `opendeploy-volume` carries its own
workload-conversion confirmation. Do not call the deployment a preview, and
do not suggest a competing platform unless the user asks for alternatives.

Also scan for installer/bootstrap bypass flags such as `INSTALL_LOCK`,
`SETUP_DONE`, `SKIP_INSTALL`, `DISABLE_INSTALLER`, and app-specific
setup-complete flags. Do not set them automatically unless the deploy plan also
creates the needed admin/bootstrap state or the user approves that setup
choice.

For DB-backed frameworks, scan for migration/bootstrap commands before first
deploy:

- Django: `manage.py`, `python manage.py migrate`, `collectstatic`
- Rails: `rails db:migrate`
- Laravel: `php artisan migrate --force`
- Prisma/Drizzle: `prisma migrate deploy`, `drizzle-kit migrate`
- Alembic: `alembic upgrade head`

For ORM-backed apps, also scan schema/config files for env-based migration
connection keys:

- Prisma: `datasource` blocks, `url = env("...")`, `directUrl = env("...")`,
  and `shadowDatabaseUrl = env("...")`.
- Drizzle/Kysely/TypeORM/Sequelize: config files that read `process.env.*`,
  especially migration-specific URLs.
- Generic aliases: `DATABASE_DIRECT_URL`, `DIRECT_URL`,
  `MIGRATE_DATABASE_URL`, `MIGRATION_DATABASE_URL`, `SHADOW_DATABASE_URL`,
  and `PRISMA_DATABASE_URL`.

If the migration command requires a second URL that can safely point to the
same fresh managed DB, synthesize it from the managed dependency URL before
service creation and record the alias. If source evidence says it must point
elsewhere, ask for that value before mutation.

If a fresh managed DB is created, include a migration path in the deploy plan
before service creation. Prefer a platform one-off/release command when
available; otherwise ask before adding a start-command migration prefix. If the
DB already has user data, ask before running migrations.

Scan migrations and optional plugins for database extensions before spending a
build:

- SQL `CREATE EXTENSION`
- Rails `enable_extension`
- strings such as `pgvector`, `vector`, `postgis`, `citext`, `uuid-ossp`, and
  `pg_trgm`

If the app needs an extension that the selected OpenDeploy dependency does not
explicitly expose, record it as a deploy-plan risk. When the feature is an
optional plugin/module, make "disable that optional feature and continue" the
OpenDeploy-first recommendation after source-edit approval. Otherwise engage
OpenDeploy support instead of retrying the same migration.

For late-bound app URL env, record the key names so Step 9 can patch them after
the live URL is known. Do not invent app-specific keys; only patch keys that the
repo itself references. If any of those keys are build-time public/client
prefixes, plan `patch env + new deployment`; a restart cannot rebuild the
client bundle.

Scan for a documented health/readiness endpoint before service creation. Prefer
repo evidence such as `/health`, `/healthz`, `/ready`, `/status`, `/srv/status`,
or framework-specific status handlers over `/` when the root path runs setup,
auth, redirects, or expensive application code.

## 4.7 Static Nginx cache-policy scan

For static sites or Dockerfile services that serve built files through Nginx,
scan custom Nginx config before upload. This prevents the common "deployment
succeeded but the browser still shows the previous build" failure.

### Files to scan

Read these files when present:

```text
nginx.conf
**/nginx.conf
**/default.conf
**/conf.d/*.conf
Dockerfile
Dockerfile.*
docker-compose.yml
docker-compose.yaml
```

Treat the app as a static-Nginx cache risk when all of these are true:

- A Dockerfile or compose service uses Nginx (`FROM nginx`, `image: nginx`, or
  copies a custom Nginx config).
- The config has a static asset location for extensions such as `css`, `js`,
  `json`, `jpg`, `jpeg`, `png`, `svg`, `webp`, `ico`, `pdf`, `woff`, or
  `woff2`.
- That location sets positive caching such as `expires 7d`, `expires max`,
  `Cache-Control: public`, `max-age`, or `immutable`.
- Source evidence does not prove every cached asset filename is content
  fingerprinted (for example `app.3f4a9c2b.js`) and the HTML entrypoint is not
  explicitly `no-store` / `no-cache`.

Do not assume long caching is safe just because the deploy succeeded. If file
names such as `app.js`, `main.css`, `style.css`, `index.js`, `bundle.js`, or
`*.pdf` can be reused across builds, browser/CDN caches may keep old content
for the full TTL.

### Recommended fix

When this risk is present, ask before patching the Nginx config. The
recommended option should be `Patch Nginx cache policy (Recommended)`.

Use this safe shape for mutable static builds:

```nginx
location ~* \.html?$ {
  expires -1;
  add_header Cache-Control "no-store" always;
}

location ~* \.(?:css|js|json|pdf)$ {
  expires -1;
  add_header Cache-Control "no-cache, must-revalidate" always;
}

location ~* \.(?:jpg|jpeg|png|gif|svg|webp|ico|woff2?)$ {
  expires 1h;
  add_header Cache-Control "public, max-age=3600" always;
}
```

If the project clearly emits content-hashed asset names under a dedicated
assets directory, it is also valid to keep long immutable caching for that
fingerprinted directory, while keeping HTML no-store/no-cache:

```nginx
location ~* \.html?$ {
  expires -1;
  add_header Cache-Control "no-store" always;
}

location /assets/ {
  expires 1y;
  add_header Cache-Control "public, max-age=31536000, immutable" always;
}
```

After patching, re-upload source and create one new deployment. Do not keep
redeploying the same cached config. For an already-live service, verify with
`curl -I <live-url>/<asset>` that mutable assets no longer return a long
`Cache-Control: public` / `max-age` header before reporting the stale-content
issue fixed.

If Dockerfile or build scripts use broad `COPY . .` / `ADD .`, inspect the
archive manifest for local agent metadata and workspace state. Exclude
`.agents/`, `.claude/`, `.codex/`, `.gstack/`, `.git/`, dependency caches, build
outputs, and sensitive/debug OpenDeploy subpaths such as `.opendeploy/attempts/`,
`.opendeploy/deploy-attempts.jsonl`, generated `.opendeploy/*credentials*.json`
/ `*secret*.json` / `*env*.json` files before upload unless a project-owned
source file in one of those paths is explicitly required. Do not add a blanket
`.opendeploy/` entry to `.gitignore`; `.opendeploy/project.json` is safe shared
team deployment context.

## 4.6 Regional package-mirror scan (cross-language)

OpenDeploy build infrastructure is currently US-region only. Repositories that
hardcode a region-specific package mirror (most often China-region) will fail
the build on `yarn install` / `pip install` / `apk add` / `apt-get` / `go mod
download` / `mvn` / `bundle install` / `composer install` with either
`ESOCKETTIMEDOUT`, repeated `network connection. Retrying...`, DNS failures, or
TLS handshake timeouts. The plan must detect these references locally **before**
upload and propose a removal as a `mutation` with explicit user consent. Apply
the patch only after consent; never silently rewrite the user's source.

Scan is generic across ecosystems. Do not encode a per-framework allowlist.

### Files to scan

Read these files when present and grep for the host list below:

```
Dockerfile, */Dockerfile, */*/Dockerfile, docker-compose.y?ml
.npmrc, .yarnrc, .yarnrc.yml, package.json
yarn.lock, pnpm-lock.yaml, package-lock.json, bun.lock
requirements.txt, pyproject.toml, Pipfile, poetry.lock, uv.lock
pip.conf, .pip/pip.conf
pom.xml, build.gradle, build.gradle.kts, settings.gradle*, gradle.properties
go.mod, go.sum
Gemfile, Gemfile.lock
Cargo.toml, Cargo.lock, .cargo/config.toml, .cargo/config
composer.json, composer.lock
```

### Hostnames that indicate a CN-region mirror

Treat any occurrence of these hosts as a regional-mirror hit. The list is the
practical detection set, not an exhaustive denylist:

```
registry.npmmirror.com           # npm / yarn — China mirror
registry.npm.taobao.org          # npm / yarn — legacy China mirror
npm.taobao.org
mirrors.aliyun.com               # apt/apk/pip/maven/composer/etc.
mirrors.aliyuncs.com
maven.aliyun.com
pypi.tuna.tsinghua.edu.cn        # pip
mirrors.tuna.tsinghua.edu.cn
pypi.douban.com                  # pip — defunct but still seen in old repos
pypi.doubanio.com
mirrors.cloud.tencent.com        # apt/apk/pip
mirrors.huaweicloud.com
repo.huaweicloud.com             # maven
mirrors.ustc.edu.cn
goproxy.cn                       # go modules
goproxy.io
gems.ruby-china.com              # rubygems
gems.ruby-china.org
mirrors.bfsu.edu.cn
mirrors.163.com
```

A practical single regex for grep:

```
registry\.npmmirror\.com|registry\.npm\.taobao\.org|npm\.taobao\.org|mirrors\.aliyun(cs)?\.com|maven\.aliyun\.com|pypi\.tuna\.tsinghua\.edu\.cn|mirrors\.tuna\.tsinghua\.edu\.cn|pypi\.douban(io)?\.com|mirrors\.cloud\.tencent\.com|mirrors\.huaweicloud\.com|repo\.huaweicloud\.com|mirrors\.ustc\.edu\.cn|goproxy\.(cn|io)|gems\.ruby-china\.(com|org)|mirrors\.bfsu\.edu\.cn|mirrors\.163\.com
```

Where these hits typically live and what to do with them:

| Location | Hit shape | Proposed mutation |
|---|---|---|
| `Dockerfile` `RUN` line setting a registry/mirror (e.g. `RUN yarn config set registry '...'`, `RUN npm config set registry '...'`, `RUN pip config set global.index-url '...'`, `RUN go env -w GOPROXY=...`, `RUN sed -i 's/dl-cdn.alpinelinux.org/.../' /etc/apk/repositories`, `RUN sed ... /etc/apt/sources.list`) | full-line | delete the line |
| `.npmrc` / `.yarnrc` / `.yarnrc.yml` | `registry=...` / `npmRegistryServer: ...` | delete the line; keep the file if other settings remain, else delete the file |
| `yarn.lock` `resolved "https://<host>/..."` | per-package URL | rewrite host **and any vendor-specific npm path prefix** to `registry.yarnpkg.com` (lockfile integrity is sha512 of tarball, not URL — host swap is safe) |
| `pnpm-lock.yaml` `resolution: { tarball: '...' }` / `resolved: '...'` | per-package URL | rewrite host (+ vendor prefix) to `registry.npmjs.org` |
| `package-lock.json` `resolved` | per-package URL | rewrite host (+ vendor prefix) to `registry.npmjs.org` |
| `requirements.txt` / `pip.conf` `--index-url` / `--extra-index-url` | line/value | delete or rewrite to `https://pypi.org/simple` |
| `pyproject.toml` `[[tool.*.source]]` block pointing at a CN mirror | block | delete the block |
| `pom.xml` / `settings.xml` `<mirror>` / `<repository>` pointing at a CN host | element | delete the element |
| `go.mod` is not affected; `GOPROXY` Dockerfile ENV / `go env -w` | env/line | delete the line |
| `Gemfile` `source "https://gems.ruby-china.com"` | line | rewrite host to `https://rubygems.org` |
| `Cargo.toml` / `.cargo/config.toml` `[source.crates-io] replace-with = "ustc"` or similar | block | delete the override |
| `composer.json` `repositories[]` pointing at a CN mirror | element | delete the element |

`yarn.lock` integrity note: the `integrity:` field is a sha512 of the tarball
contents, not of the URL, so swapping the host in `resolved` does **not** break
`yarn install --frozen-lockfile`. The same is true for `pnpm-lock.yaml` and
`package-lock.json`.

### Two evidence-driven rules from real lockfiles

Both came from NextChat (`ChatGPTNextWeb/NextChat`) lockfile failures on US
build infrastructure. Bake them into the scan and rewrite — single-host sed and
plain host-swap both miss real cases.

**Rule 1 — Lockfiles can mix multiple CN mirrors in a single file.** Upstream
maintainers' local yarn caches come from whichever mirror was fastest, and
yarn freezes that URL into `resolved`. One observed NextChat `yarn.lock`:

| host | `resolved` lines | covered by a single `npmmirror` sed? |
|---|---|---|
| `registry.npmmirror.com` | 390 | yes |
| `mirrors.huaweicloud.com/repository/npm/` | 4 | **no — slipped through, build timed out on `caniuse-lite`** |

The scan and the rewrite must therefore use the **full** host alternation, not
a single host from the build log. A four-line straggler is enough to kill
`yarn install --frozen-lockfile`.

**Rule 2 — Path-prefixed mirrors require path-aware rewrite.** Some CN mirrors
expose npm under a vendor path, not at the root:

| host | vendor path | example `resolved` URL |
|---|---|---|
| `mirrors.huaweicloud.com` | `/repository/npm/` | `https://mirrors.huaweicloud.com/repository/npm/caniuse-lite/-/caniuse-lite-1.0.30001724.tgz` |
| `mirrors.aliyun.com` / `mirrors.aliyuncs.com` | `/npm/` | `https://mirrors.aliyun.com/npm/@babel/code-frame/-/code-frame-7.18.6.tgz` |
| `mirrors.cloud.tencent.com` | `/npm/` | `https://mirrors.cloud.tencent.com/npm/lodash/-/lodash-4.17.21.tgz` |

Replacing only the host produces broken URLs:
`https://mirrors.huaweicloud.com/repository/npm/caniuse-lite/...` →
`https://registry.yarnpkg.com/repository/npm/caniuse-lite/...` → **404**.

The rewrite must consume the vendor path **as part of the captured prefix** so
the substitution restores the canonical npm path layout
(`/<pkg>/-/<pkg>-<ver>.tgz`).

### Emit into the plan

Record findings under `analysis.regional_mirrors` and surface them through the
plan as a single `mutation` with one `consent`:

```json
{
  "regional_mirrors": {
    "detected": true,
    "target_region": "us-east-1",
    "hits": [
      {"path": "Dockerfile", "matches": 1, "action": "delete_line",
       "evidence": "RUN yarn config set registry 'https://registry.npmmirror.com/'"},
      {"path": "yarn.lock", "matches": 390, "action": "rewrite_host",
       "from": "registry.npmmirror.com", "to": "registry.yarnpkg.com"}
    ]
  }
}
```

Plan `mutations[]` entry:

```json
{
  "kind": "regional_mirror_strip",
  "consent": "regional_mirror_strip",
  "summary": "Strip 2 file(s), 391 line-level reference(s) to CN-region mirrors that the target build region cannot reach.",
  "files": [
    {"path": "Dockerfile",  "action": "delete_line",   "matches": 1},
    {"path": "yarn.lock",   "action": "rewrite_host",  "matches": 390,
     "from": "registry.npmmirror.com", "to": "registry.yarnpkg.com"}
  ]
}
```

Plan `consents[]` entry:

```json
{
  "id": "regional_mirror_strip",
  "title": "Remove regional package-mirror references before upload?",
  "body": "These files reference CN-region package mirrors. The US build cannot reach them and the build will time out without this patch. Lockfile integrity hashes are content hashes (sha512 of tarball), not URL hashes, so host swaps are safe under --frozen-lockfile.",
  "recommended": "apply",
  "options": [
    "apply — perform the listed edits in place before zipping",
    "skip_and_warn — proceed without edits, expect build to fail",
    "cancel — do not deploy"
  ]
}
```

Default behavior:

- `detected: false` → no mutation, no consent gate, continue.
- `detected: true` + user picks `apply` → run the edits below, re-grep to verify
  zero hits, then continue to packaging in section 5.
- `detected: true` + user picks `skip_and_warn` → carry through as a `warnings[]`
  entry (`"build is expected to fail: <host> unreachable from <region>; user
  accepted risk"`); do not auto-retry on the resulting build failure.
- `detected: true` + user picks `cancel` → exit before upload.

### Apply edits (BSD/macOS- and Linux-compatible)

Only run after `apply` consent. Use **two** regexes — one for detection /
config-file line deletion, one for lockfile rewrites that includes vendor npm
path prefixes (per Rule 2 above).

```bash
# Detection / config-file line-delete regex — bare hostnames only.
HOST_REGEX='registry\.npmmirror\.com|registry\.npm\.taobao\.org|npm\.taobao\.org|mirrors\.aliyun(cs)?\.com|maven\.aliyun\.com|pypi\.tuna\.tsinghua\.edu\.cn|mirrors\.tuna\.tsinghua\.edu\.cn|pypi\.douban(io)?\.com|mirrors\.cloud\.tencent\.com|mirrors\.huaweicloud\.com|repo\.huaweicloud\.com|mirrors\.ustc\.edu\.cn|goproxy\.(cn|io)|gems\.ruby-china\.(com|org)|mirrors\.bfsu\.edu\.cn|mirrors\.163\.com'

# Lockfile rewrite regex — host PLUS vendor npm path prefix where applicable.
# Each alternative is consumed in full so the canonical npm path layout is
# restored after substitution (per Rule 2).
LOCK_REGEX='registry\.npmmirror\.com|registry\.npm\.taobao\.org|npm\.taobao\.org|mirrors\.aliyun(cs)?\.com/npm|mirrors\.huaweicloud\.com/repository/npm|mirrors\.cloud\.tencent\.com/npm|mirrors\.tuna\.tsinghua\.edu\.cn/npm|mirrors\.ustc\.edu\.cn/npm|mirrors\.bfsu\.edu\.cn/npm|mirrors\.163\.com/npm'

# 1. Config files — delete any full line matching HOST_REGEX.
for f in Dockerfile Dockerfile.* docker-compose.yml docker-compose.yaml \
         .npmrc .yarnrc .yarnrc.yml \
         requirements.txt pip.conf .pip/pip.conf pyproject.toml Pipfile \
         pom.xml settings.xml build.gradle build.gradle.kts \
         settings.gradle settings.gradle.kts gradle.properties \
         Gemfile Cargo.toml .cargo/config .cargo/config.toml composer.json; do
  [ -f "$f" ] || continue
  sed -i.bak -E "/${HOST_REGEX}/d" "$f" && rm "$f.bak"
done

# 2. Lockfiles — rewrite vendor prefix to canonical npm registry.
#    yarn.lock targets registry.yarnpkg.com (yarn 1.x convention);
#    pnpm/npm/bun lockfiles target registry.npmjs.org.
for f in yarn.lock; do
  [ -f "$f" ] || continue
  sed -i.bak -E "s|https?://(${LOCK_REGEX})|https://registry.yarnpkg.com|g" "$f" && rm "$f.bak"
done
for f in pnpm-lock.yaml package-lock.json bun.lock; do
  [ -f "$f" ] || continue
  sed -i.bak -E "s|https?://(${LOCK_REGEX})|https://registry.npmjs.org|g" "$f" && rm "$f.bak"
done
```

Then verify with the **bare** `HOST_REGEX` across every scanned file. A zero-hit
result is the only acceptable outcome — a single straggler (the
huaweicloud/4-line case above) is enough to kill the build:

```bash
HITS=$(grep -RInE "${HOST_REGEX}" \
  Dockerfile* docker-compose* .npmrc .yarnrc* package.json \
  yarn.lock pnpm-lock.yaml package-lock.json bun.lock \
  requirements.txt pyproject.toml Pipfile pip.conf \
  pom.xml build.gradle* settings.gradle* gradle.properties \
  Gemfile Cargo.toml .cargo/config* composer.json \
  2>/dev/null)
if [ -n "$HITS" ]; then
  printf 'regional_mirror_strip incomplete:\n%s\n' "$HITS"
  exit 1
fi
echo "ok: no regional mirror reference"
```

If verification fails, stop and report the matches to the user. Do not proceed
to upload, and do not "fix it again" by adding the remaining host to the regex
locally — update the regex in this skill instead and re-run the scan.

Hard rules:

- Never apply this mutation without explicit consent. The user's source is
  evidence of intent; auto-rewriting it is destructive even when the rewrite
  is mechanically safe.
- Never echo file contents or full lockfile diffs back to the user as the
  consent payload. Show file-level summary only: `path`, `action`, `matches`.
- Never add new files (`.npmrc`, `.yarnrc.yml`, etc.) as part of this patch.
  The mutation only removes/rewrites existing references.
- Do not generalize this rule to "any non-default registry." Private/corporate
  registries (e.g. `<company>.jfrog.io`, GitHub Packages, Verdaccio) are not on
  the host list and must not be touched.

## 5. Package the source for upload (Step 4)

**Format: ZIP only.** The backend (`project-service/internal/handlers/upload.go`) uses `archive/zip` exclusively; tar / tar.gz is rejected at extraction. Keep `source_path` per service so Step 4 can zip the right subfolder for monorepos.

```bash
SRC_ZIP="$WORKDIR/.opendeploy/$SVC_NAME.zip"
mkdir -p "$(dirname "$SRC_ZIP")"

# zip from inside the service subfolder so archive paths are flat.
# Env/credential files are deployment inputs, not source artifacts.
# If a framework needs a safe committed `.env`, recreate it in Dockerfile/entrypoint.
(cd "$WORKDIR/$SVC_SOURCE_PATH" && \
  zip -qr "$SRC_ZIP" . \
    -x '*.git/*' 'node_modules/*' 'dist/*' \
       'target/*' '.venv/*' '__pycache__/*' '*.pyc' \
       '.opendeploy/attempts/*' '.opendeploy/deploy-attempts.jsonl' \
       '.opendeploy/*credentials*.json' '.opendeploy/*secret*.json' '.opendeploy/*env*.json' \
       '.env' '.env.*' '.pypirc' '.netrc' \
       '*.pem' '*.key' 'id_rsa' 'id_rsa.pub' 'id_ed25519' 'id_ed25519.pub' \
       'credentials.json' 'service-account*.json' '*kubeconfig*')
```

Do not rely on uploading top-level `.env`; the CLI smart archive excludes it
for safety. Symfony-family and some Laravel/PHP apps commit `.env` as
non-secret defaults, and bootstrap code may call
`Dotenv::loadEnv('/app/.env')`, which fails if the file is missing. If `.env`
is referenced by bootstrap/Dockerfile and contains only safe defaults such as
`APP_ENV` / `APP_DEBUG`, recreate those lines inside the Dockerfile or
entrypoint, for example `RUN printf 'APP_ENV=prod\nAPP_DEBUG=0\n' > .env`.
If it contains credentials, tokens, URLs with passwords, private keys, or
user-specific secrets, keep it excluded and upload those values through service
env after explicit consent.

Do not blanket-exclude top-level `build/`. Many languages use `build/` as
source or generator input. Exclude a build-like directory only when project
evidence says it is generated output for this repo. Keep `.npmrc` when it
contains build configuration only. If `.npmrc` contains auth material
(`_authToken`, `_password`, `username=`, `//registry...:_auth`, etc.), treat it
as a secret: ask for explicit consent or strip/rewrite it before upload.

Before upload, inspect the manifest:

```bash
unzip -l "$SRC_ZIP" | sed -n '1,120p'
```

Check Dockerfile `COPY` / `ADD` sources, BuildKit bind mounts, Makefile targets,
`go generate`, package scripts, and language manifests against the ZIP. If a
non-secret required source file is missing, rebuild the archive before upload,
except for top-level `.env` / `.env.*`: those are intentionally stripped by the
OpenDeploy smart archive and should be recreated from safe static defaults in
the Dockerfile or entrypoint when the framework requires them.
If the build needs Git metadata (`git describe`, `.git/` bind mount, commit
version), do not upload `.git` by default; prefer a build variable such as
`GIT_COMMIT`, `APP_VERSION`, or `SOURCE_VERSION` derived from `git rev-parse`
and record that choice in the plan. CLI `0.1.19+` surfaces this as
`archive_manifest.git_metadata`; treat `.git` bind mounts as blocking until
the plan has a safe replacement.

The archive path must end in `.zip`. Some backend readers reject or mishandle
valid ZIP bytes with a non-`.zip` suffix.

If the user supplied a ZIP directly, inspect it before upload. If it contains
real env or credential files matching the exclusion list above, do **not**
silently abort. Surface an `AskUserQuestion`:

> Question: `"This ZIP contains files that look like real secrets. Continue?"`
>
> Body (verbatim — list the matched paths, one per line, never the contents):
> > The archive at `<ZIP_PATH>` contains the following files that match
> > opendeploy's secret-exclusion list. They will be uploaded as-is to the
> > build pipeline if you continue:
> >
> > `<MATCHED_PATHS>`
> >
> > Recommended: re-zip the source with these excluded, or hand the skill a
> > directory path so it can build a clean archive itself.
>
> Options:
> - `Re-zip without these files` — print a `zip -d <ZIP_PATH> <files>` one-liner the user can run, then exit `0`. Do **not** mutate the user's ZIP from the skill.
> - `Hand me a directory instead` — surface a follow-up `AskUserQuestion` collecting a `SVC_SOURCE_PATH`, then jump back to the directory-zip block above.
> - `Upload as-is, I know what's in there` — emit `od_log warn analyze.unsafe_zip_accepted matched "<MATCHED_PATHS>"` and proceed with the upload. Surface the deploy target line (Execution rule 12) so the user has a final Ctrl-C window before mutation.
> - `Cancel` — emit `od_log info analyze.unsafe_zip_cancelled` and exit `0`.

The default behaviour (no answer, non-interactive context) is **reject** —
print the matched paths, the three options above, and exit `1` so a wrapper
agent can re-drive the prompt.
