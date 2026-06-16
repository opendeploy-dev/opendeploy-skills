# Operate Reference - CLI Only

Use this reference for redeploys, env rotation, resize, rollback, cancellation,
and failed-deploy triage. Default execution is through `@opendeploydev/cli`.

## Operation Matrix

| Intent | Pattern |
|---|---|
| Redeploy current source | `opendeploy deployments create --project "$PROJECT_ID" --service "$SERVICE_ID" --json` |
| Redeploy with new source | `opendeploy upload update-source "$PROJECT_ID" "$SOURCE_PATH" --project-name "$PROJECT_NAME" --region-id "$REGION_ID" --json`, then create deployment |
| Rotate env vars / secrets | `opendeploy services env patch ...` or `opendeploy services env reconcile ...`, then redeploy so the pod receives the new env |
| Delete an env key | `opendeploy services env unset "$PROJECT_ID" "$SERVICE_ID" KEY --confirm-env-upload --json`; ask first for DB/cache-generated keys |
| Resize a service | `opendeploy services update "$SERVICE_ID" --cpu-request ... --memory-limit ... --json`; ask first because it affects live traffic/resources |
| Add a DB/cache | `opendeploy dependencies create`, `dependencies wait/env`, `services env reconcile`, then redeploy |
| Rename subdomain | `domains check-subdomain`, `domains list`, `domains update-subdomain`; no redeploy |
| Cancel a running deployment | Ask first, then `opendeploy deployments cancel "$DEPLOYMENT_ID" --json`, then wait |
| Roll back | List successful deployments/versions, ask first, then use the supported rollback route with `--confirm-rollback` |
| Triage failure | `opendeploy deployments logs`, `opendeploy logs diagnose`, then patch the plan/config before retry |

## Env Rules

- Prefer patch/unset/reconcile over full replacement.
- Key deletion is a reversible operation, but deleting DB/cache-generated keys
  can break the service. Ask before deleting `DATABASE_URL`, `MYSQL_URL`,
  `MONGODB_URI`, `REDIS_URL`, or similar managed keys.
- Never print decrypted env values.
- After every env mutation, read back key names and verify required keys exist.
- **Verify the patch actually replaced the dependency-injected row.** After
  `services env patch` on a key the dependency layer also writes (e.g.
  `DATABASE_URL`, `DATABASE_USER`, `DATABASE_PASSWORD`), run
  `opendeploy services env get "$PROJECT_ID" "$SERVICE_ID" --json` and confirm
  the key appears exactly once in the `variables` array. Redacted output is
  enough here; do not reveal values. The backend's `service_variables` table has
  been observed to accumulate one `source: "user"` row plus one
  `source: "dependency"` row for the same key, with non-deterministic winner at
  deploy-injection time. If duplicates appear, the patch did nothing useful —
  fall back to a Dockerfile `CMD` / `start_command` wrapper that constructs the
  value from the alias env at container startup, so the runtime always wins
  regardless of which row K8s picks.
- Env changes are not hot-loaded into a running container. Ask before rollout,
  then create a new deployment for runtime, build-time, and mixed env changes.
  `services restart` has been observed to keep the old pod env after env patch.
- **Treat `restart_required: true` as a hint, not a contract.** A `services
  restart` bounces pods but uses the existing K8s Deployment spec, so changes
  that affect the pod spec (`runtime_variables`, `build_variables`,
  `start_command`, `build_command`, `dockerfile_path`, resource caps) may not
  take effect on restart even though the CLI envelope says it should. After any
  service/env/config patch that touches the pod spec, prefer
  `opendeploy deployments create` over `services restart` to guarantee the new
  spec rolls out.

## Consent Gates

Ask before:

- restart/stop/start
- resize
- deployment cancel/retry during an incident
- rollback/promote
- custom domain
- paid/billing operation
- destructive delete
- full env replacement

Project/service/dependency/domain deletes are dashboard handoffs unless the CLI
and backend explicitly return a safe, consent-gated operation for that exact
resource.

Rollback/promote currently use the gateway consent kind
`live_service_change`. The CLI exposes friendly flags:

```bash
opendeploy services versions rollback "$PROJECT_ID" "$SERVICE_ID" "$VERSION_ID" --confirm-rollback --json
opendeploy versions promote "$VERSION_ID" --confirm-promote --json
```

Do not retry rollback with `confirm=true` query/body payloads; the backend gate
checks the consent header emitted by the CLI flags above.

## Rollback Verification Contract

Rollback is a rollout, not just a metadata update. Never report rollback success
from HTTP 200 alone.

Required response invariant:

- `services versions rollback ... --json` must return a non-empty
  `deployment_id`.

If `deployment_id` is missing, stop immediately and report:

- rollback response body
- target `version_id`
- `services get <service-id>` current version/deployment fields
- `services versions list/current`
- `deployments list --project <project-id> --service <service-id>`

Phrase it as: "Rollback metadata may have changed, but no rollback deployment
was created, so traffic has not been proven to move." Do not say "rollback
successful." Do not keep retrying unless a backend fix was deployed or the user
explicitly asks for another attempt after reviewing the inconsistent state.

If `deployment_id` is present, verify the rollout:

```bash
opendeploy deploy wait "$ROLLBACK_DEPLOYMENT_ID" --follow --json
opendeploy deployments get "$ROLLBACK_DEPLOYMENT_ID" --json
opendeploy deployments list --project "$PROJECT_ID" --service "$SERVICE_ID" --json
opendeploy services get "$SERVICE_ID" --json
opendeploy services versions current "$PROJECT_ID" "$SERVICE_ID" --json
opendeploy services logs "$PROJECT_ID" "$SERVICE_ID" --query tail=200 --json
```

Completion criteria:

- the rollback deployment appears in deployment history
- deployment terminal status is successful/active
- service read-back points at the target version or rollback deployment
- service health/logs do not show the previous version still running

If `versions.is_production` flipped but no rollback deployment exists, treat it
as a platform false-success bug. The safest user-facing answer is that rollback
did not complete and the platform state needs repair; avoid dashboard handoff
unless the dashboard route is known to create and wait for a rollback
deployment.

## Account Binding

If a local deploy credential is not linked and an operation returns
`bind_required`, stop and surface the account-binding URL from:

```bash
opendeploy deploy report "$DEPLOYMENT_ID" --json
```

Do not construct or print `bind_sig` manually. Show only the full binding URL.

## Verification

After every mutation:

```bash
opendeploy services get "$SERVICE_ID" --json
opendeploy deployments get "$DEPLOYMENT_ID" --json
opendeploy services logs "$PROJECT_ID" "$SERVICE_ID" --query tail=200 --json
```

If verification fails, report the exact failing invariant and stop rather than
stacking retries.
