---
name: opendeploy-database
version: "0.0.20"
description: Plan, create, wait for, analyze, diagnose, query/inspect, temporarily expose, or rotate credentials on OpenDeploy managed Postgres, MySQL, MongoDB, and Redis dependencies. Use when the user says database, db, cache, Postgres, PostgreSQL, MySQL, MongoDB, Mongo, Redis, connection string, DATABASE_URL, REDIS_URL, MONGODB_URI, dependency health, dependency env, create DB, add Redis, debug managed dependency env injection, check a table, count users, inspect DB data, rotate database password, change DB password, reset DB credentials, or update database username.
user-invokable: true
---

# OpenDeploy Database

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

Supported managed dependencies:

```text
postgres
mysql
mongodb
redis
```

Build every user-facing DB choice from the active catalog:

```bash
opendeploy dependencies list --json
```

Do not advertise engines that are not in that response. In particular, do not
offer "Managed MariaDB" or "Managed SQLite" as OpenDeploy database options.
If source evidence says the app supports MariaDB and the catalog exposes MySQL,
offer `Managed MySQL` and describe it as the compatible OpenDeploy engine. If
source evidence says the app supports SQLite, route that to an OpenDeploy
volume/storage decision; it is an app file, not a managed DB dependency. The
user-facing option should be `Use SQLite on OpenDeploy volume`, not
`Managed SQLite`.
Do not advertise ClickHouse as managed until backend and CLI support create,
wait, and env mapping.

Version compatibility matters, but it is not a default blocker. If repo docs or
config declare a minimum DB engine version, compare that requirement with the
active OpenDeploy dependency catalog before creation. If the catalog version is
older than the app documents, surface it as a verification note, use the
available managed engine, and plan a targeted smoke test after deploy. Do not
say it is fine from memory. Pause only when source evidence shows the app
explicitly refuses the catalog version or when the user asked for an exact DB
version. If the app can use another catalog-supported engine that satisfies the
version requirement, offer that supported engine first. Do not offer engines
missing from the catalog.

## Detect / create / wait / read env

```bash
opendeploy dependencies detect --json                                # which DBs the project needs
opendeploy dependencies create --body .opendeploy/dependency-<dependency>.json --json
opendeploy dependencies wait <project-id> --json                     # block until status=running
opendeploy dependencies env <project-id> --json                      # injected env keys (names only)
opendeploy dependencies status <project-id> --json                   # raw status + env vars
opendeploy dependencies preview-env-vars --project <project-id> --json
opendeploy dependencies update-connection <project-id> <project-dependency-id> --body db-credentials.json --json
opendeploy dependencies port-access status <project-id> <project-dependency-id> --json
```

For multi-dependency setup, use `dependencies batch-create`.

Before create, ask how credentials should be set when the app will use the DB:

```text
question: "How should OpenDeploy set database credentials?"
options:
  - label: "Use secure generated credentials (Recommended)"
    description: "The agent generates non-placeholder credentials locally, keeps values secret in a 0600 body file, and OpenDeploy injects the connection env."
  - label: "I have credentials"
    description: "Wait for the username/password you want and send them via a 0600 JSON body file."
  - label: "Pause before database"
    description: "Stop before creating or changing the database."
```

Do not ask non-technical users to invent a password unless they choose "I have
credentials". For the recommended generated path, first check repo docs/env
examples for credential constraints such as minimum length, exact length,
maximum length, or allowed characters. Generate a username such as
`app_<8 random hex chars>` and a random password that satisfies the app
contract and OpenDeploy's backend validator. If no app-specific constraint
exists, use a 32+ char CSPRNG password; if the app requires exactly 16 chars or
a max length, generate that length with a safe charset such as `A-Za-z0-9_-`.
Write credentials to the dependency create/update body. Never use `admin` /
`changeme`. Never put a password directly in the shell command; write a
temporary body file with mode `0600`.
Never print the generated or user-provided DB/cache credentials in chat, logs,
or final reports. If an app's web installer needs the values, provide key names
and tell the user to reveal them from the dashboard env UI or the local 0600
body file under `.opendeploy/`; use `--show-secrets` only after explicit
secret-reveal approval.

## Hard rule for deploy

```text
create dependency -> wait running -> fetch env -> merge service env -> create service -> read back env -> deploy
```

If the dependency env is missing, stop before deployment. Do not retry deploy
until the env contract is fixed.

Use `opendeploy dependencies wait <project-id> --json` when available. If the
agent runtime uses a background monitor instead, the monitor script must be
wait-safe: `pending`, `deploying`, empty reads, unchanged status, and transient
read errors are not process failures. Emit the current state and exit `0` while
waiting. Exit non-zero only for terminal dependency states such as `failed` or
for a clear command/schema error. After any monitor exits non-zero, immediately
run `opendeploy dependencies status <project-id> --json` before reporting
failure; if the dependency is now `running`, continue.

If `dependencies env/status` shows placeholder secrets, compare them to the app
env contract. Stop before service creation only when a consumed key, generated
connection URL, or synthesized consumed alias would receive a placeholder. If
the placeholders are unused aliases and the consumed canonical key is real,
continue with a key-only warning. For an existing running dependency whose
consumed credential is placeholder-like, use `opendeploy dependencies
update-connection ... --body db-credentials.json --json` for
Postgres/MySQL/MongoDB, wait again, then read back env before creating or
redeploying the app. For Redis, do not use `update-connection` as the normal
repair path: use the exact returned `REDIS_URL` / `REDIS_*` values when they
are non-placeholder, and if Redis auth fails after a rotation, stop and ask the
user to recreate the Redis dependency from the dashboard or engage OpenDeploy
support.
After credential rotation, patch/reconcile every consuming service runtime env
from the updated dependency env and create new deployments for those services.
Updating the dependency alone does not make already-running app containers see
the new password.

## Inspect / query a managed DB without redeploying

When the user asks to inspect database state (for example "are there users?",
"count rows", "check this table", "does this migration exist?"), do **not**
recommend a temporary app debug endpoint or source edit first. That requires a
redeploy and leaves risky application code behind. Prefer the platform DB access
path:

1. Confirm the target dependency and table/query from context.
2. Ask explicit consent to temporarily expose the managed dependency TCP port
   and reveal credentials to the local agent process. This is
   `security_sensitive` consent.
3. Enable external TCP access:

   ```bash
   opendeploy dependencies port-access enable <project-id> <project-dependency-id> \
     --confirm-security-sensitive --json
   ```

   If the installed CLI does not have `dependencies port-access`, use the API
   escape hatch:

   ```bash
   opendeploy api post /projects/<project-id>/dependencies/<project-dependency-id>/port-access/enable \
     --confirm-security-sensitive --json
   ```

4. Read credentials with explicit secret-reveal consent and keep them in a
   `0600` temp file. Do not print them. Prefer connection files/env accepted by
   the DB client over password-in-argv.
5. Run the smallest read-only query needed. Examples:

   - Postgres: `psql` with `PGPASSFILE=.opendeploy/.pgpass`.
   - MySQL/MariaDB-compatible: `mysql` with a temporary defaults file.
   - MongoDB: `mongosh` with the URI in a temporary file/env var.
   - Redis: `redis-cli` with credentials kept out of chat/output.

6. Immediately disable external TCP access, even if the query fails:

   ```bash
   opendeploy dependencies port-access disable <project-id> <project-dependency-id> --json
   ```

   API fallback:

   ```bash
   opendeploy api post /projects/<project-id>/dependencies/<project-dependency-id>/port-access/disable --json
   ```

7. Delete local temp credential files and report only redacted results.

The current backend port-access route is persistent until disabled; treat the
disable step as mandatory cleanup, not optional housekeeping. If disable fails,
surface the project/dependency IDs and ask OpenDeploy support to close the
mapping. Only use a temporary application debug endpoint + redeploy as a last
resort when dependency port access and service exec are both unavailable, and
only after explicit source-edit approval.

## Analyze

```bash
opendeploy database analyze <dependency-id> --json
opendeploy dependencies health <dependency-id> --json
opendeploy monitoring dependency-health <project-id> --json
opendeploy monitoring dependency-metrics <project-id> --json
```

Analysis should summarize health, env contract, connection readiness, and
recent dependency status. Do not run destructive DB commands from the skill.

## Rotate password / update credentials

### What rotation actually changes

For Postgres/MySQL/MongoDB, `PATCH /dependencies/{pid}/{did}/connection`
only touches the dependency:

1. `ALTER USER` / `changeUserPassword` / `CONFIG SET requirepass` inside the
   DB container.
2. Updates `project_dependencies.connection_info` and `env_vars` rows.
3. Restarts the dependency pod.

It does NOT touch consumer services. The k8s Secret `{projectName}-secrets`
that backs every service's `envFrom` was snapshotted at the service's last
deploy (via `mergeEnvVars`). Until you redeploy each consuming service, the
service's pods still hold the old `DATABASE_URL` / `REDIS_URL` / `MONGODB_URI`
and will start failing auth as soon as they reconnect.

`services restart` is NOT enough — it triggers a rolling restart but pods
re-read the same stale Secret. Only a full `deployments create` re-runs
`mergeEnvVars`, rebuilds the project Secret, and rolls the pods.

Redis/Valkey caution: do not use dependency credential rotation as a first
deploy repair path for Redis auth failures. It can leave ACL/password state and
stored env out of sync. For Redis, prefer creating with explicit credentials up
front and using the exact returned `REDIS_URL` / `REDIS_*` values. Rotate Redis
only when the user explicitly asked for credential maintenance and understands
that every consumer must be redeployed afterwards.

### Hard rule for rotation

```text
Postgres/MySQL/MongoDB:
update-connection -> dependencies wait running
                  -> dependencies env (verify new values)
                  -> for each consuming service: deployments create
                  -> deploy wait per service

Redis first-deploy auth failure:
use exact returned REDIS_URL -> try at most one URL-shape correction
                            -> if still failing, recreate dependency or support
```

If any consumer redeploy fails or is skipped, the rotation is INCOMPLETE.
Do not declare success.

### Step 1 — change the credential

```bash
umask 077
# Write { "password": "<new-password>" } or accepted username/password fields to
# this file. Never put real passwords in argv.
opendeploy dependencies update-connection <project-id> <dependency-id> \
  --body .opendeploy/db-credentials.json --json
```

Optional `--username <new-username>` is accepted for MySQL only. PostgreSQL and
MongoDB reject username changes — pass `--password` only. Avoid Redis/Valkey
password rotation in deploy repair flows; if it has already produced
`invalid username-password pair` or `user is disabled`, stop and ask for
dependency recreation or OpenDeploy support.

Backend constraints (validated server-side, fail closed):

- Dependency status must be `running`. `deploying`, `stopping`, `deleting`
  return 409 / 400.
- Password: minimum 8 characters; reject any of `' " \` $ \ ; | & ( ) ! { } < > # ~`
  and whitespace (CR / LF / TAB). Use letters, digits, and basic symbols
  (`- _ @ . , + = / ^ * ? [ ]`).
- Username (MySQL only): 1–63 chars, `[A-Za-z0-9_]` only.

Response is `202`-style:

```json
{ "message": "Connection update initiated. Database will restart with new credentials.", "status": "deploying" }
```

Do not retry on 4xx — fix the input. Only retry on 5xx / transient.

### Step 2 — wait for the dependency to come back

```bash
opendeploy dependencies wait <project-id> --json
opendeploy dependencies env <project-id> --json
```

`env` should now report a fresh `DATABASE_URL` / `MONGODB_URI` / `REDIS_URL`.
If env still reflects the old credential, stop — rotation activity failed
silently and consumer fan-out would propagate stale values.

### Step 3 — fan out to every consuming service

The project's `{projectName}-secrets` is shared by all services in the
project. Each service must be redeployed so its pods pick up the new env.

```bash
# enumerate services in the project
opendeploy services list <project-id> --json

# for EACH service in that list, trigger a fresh deployment
opendeploy deployments create \
  --project <project-id> --service <service-id> \
  --description "rotate dep <dependency-id> credentials" --json

# block on each deployment terminal status
opendeploy deploy wait <deployment-id> --json
```

`deployments create` re-runs the deploy pipeline, which re-reads the
dependency `env_vars`, rewrites `{projectName}-secrets`, and triggers a
rolling restart. Plain `services restart` is NOT a substitute and will leave
pods running on the stale Secret.

If a service does not actually consume this dependency, redeploying it is
still safe (it will rewrite the same env keys with the same non-DB values)
— but you can skip it if its env contract clearly excludes the dep keys.
Use `services env get <pid> <sid>` to confirm.

### Failure modes to watch

- Step 1 returns 200 but Step 2 reports `failed` → exec succeeded inside the
  container but the StatefulSet patch (Redis) or DB record write failed.
  Run `database analyze` and `dependencies health` to diagnose.
- Step 2 succeeds but Step 3 redeploys hang on `Waiting for database` →
  consumer service is using a hardcoded literal (not a dep env var). Inspect
  the service env contract; the rotation cannot fix hardcoded credentials.
- Step 1 fails with 400 "invalid characters" → the password contains a
  shell-dangerous character. Generate a new one from the allowed set.
