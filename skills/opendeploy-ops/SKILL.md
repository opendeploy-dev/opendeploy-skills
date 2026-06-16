---
name: opendeploy-ops
version: "0.0.20"
description: Inspect, monitor, alert on, and operate live OpenDeploy services. Use for read-only health/metrics/quota/circuit-breaker checks, alarm inspection, restart, stop, start, rollback, resize, cancel deployment, retry deployment, and other live-service operations. Use opendeploy-alarms for alarm lifecycle, notes, alarm-backed support engagement, and incident updates; use opendeploy-oncall for direct private Discord support channel handoff when no alarm exists. Read-only by default; mutations require explicit consent.
allowed-tools:
  - AskUserQuestion
  - Read
  - Bash(npm:*)
  - Bash(opendeploy:*)
  - Bash(jq:*)
user-invokable: true
---

# OpenDeploy Ops

## Invocation Preflight

If this skill is invoked directly, first run
the global CLI version gate unless another OpenDeploy skill already did:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy preflight . --json
```

The npm commands are mandatory before live-service mutations. They catch stale
global installs such as `@opendeploydev/cli@0.1.0` even when that old binary
cannot accurately report its own update status. If the installed global CLI is
older than npm latest, hand off to `opendeploy-setup` and ask via structured
`AskUserQuestion` whether to update global or skip and continue. If the user
skips, continue with the installed global CLI only for command families it
actually supports.

Live-service mutations (`restart`, `stop`, `start`, `retry`, `cancel`,
`rollback`, `promote`) require CLI `0.1.19+` because the backend ConsentGate
requires `X-OpenDeploy-Consent: live_service_change`. CLI `0.1.16` and older
do not expose the needed consent contract for these routes. If npm latest is
still below `0.1.19`, do not keep trying body/query `confirm=true` variants and
do not save a memory that OpenDeploy cannot restart; report that the CLI release
is not yet published and provide the dashboard handoff only as a temporary
fallback. Once npm latest is `0.1.19+`, ask to update global CLI before the
mutation.

Do not run separate `--version`, `jq`, raw `curl` plugin probes, or direct
plugin-root inspection.

Single skill for broad live operations after the first deploy lands: monitoring,
alarm inspection, and service operations. For alarm lifecycle actions
(`acknowledge`, `resolve`, `suppress`, alarm-backed support engagement, and
incident notes), handoff to `opendeploy-alarms` so the agent leaves a
human-visible incident trail. If the user asks to engage OpenDeploy support but
there is no alarm, hand off to `opendeploy-oncall` to return the user's private
Discord channel URL. Read-only inspection runs without consent. Any mutation,
paid action, or live-traffic change asks first.

## Runner

Examples below show the canonical `opendeploy <args>` form. If the global
command is missing or stale, use `opendeploy-setup` to install/update the
global CLI or explicitly continue with the installed global CLI. Do not switch
some commands to `npx` mid-workflow. The checked binary and the executing
binary must both be the global `opendeploy` command. If the installed global
CLI cannot run the required operation, ask to update it or stop before
mutation.

Do not define a shell function alias like `od() { … }; od …` — the auto-approve
hook rejects shell composition (`;`, `|`, `&&`), so every wrapper invocation
falls through to a permission prompt. Run the binary directly.

Always pass `--json` for machine-parsed output. Never `--show-secrets` unless
the user explicitly asked to reveal values. Env command output may show key
names, but values stay redacted in the transcript.

---

## 1. Read-only inspection (no consent needed)

### Gateway and platform

```bash
opendeploy status --json
opendeploy doctor --json
```

If `gateway: ok` and a downstream circuit breaker is `open`, the CLI is healthy
but that API area is degraded. Avoid mutating calls that depend on the open
service.

### Project, service, deployment, dependency

```bash
# Project
opendeploy projects get <project-id> --json
opendeploy projects status <project-id> --json
opendeploy projects resource-stats <project-id> --json

# Service
opendeploy services get <service-id> --json
opendeploy services health <service-id> --json
opendeploy services health-history <service-id> --json
opendeploy services metrics <service-id> --kind cpu --json
opendeploy services logs <project-id> <service-id> --query tail=300

# Deployment
opendeploy deployments list --project <project-id> --service <service-id> --json
opendeploy deployments get <deployment-id> --json
opendeploy deployments status <deployment-id> --json
opendeploy deployments logs <deployment-id> --query tail=300
opendeploy deployments build-logs <deployment-id> --follow

# Dependency
opendeploy dependencies status <project-id> --json
opendeploy monitoring dependency-health <project-id> --json
opendeploy monitoring dependency-metrics <project-id> --json
```

### Quota and billing (read)

```bash
opendeploy billing quota --json
opendeploy monitoring quota --json
opendeploy resource-stats --json
```

`projects overview` and `billing current` are optional account/dashboard
endpoints. Use them only after the core project/service checks succeed and only
when the credential is account-bound. If they return HTTP 404 or HTTP 401, do
not report "Endpoints unavailable on this credential" as a failure. Say the
account-only/optional endpoint was skipped, then continue with service-level
health, logs, metrics, quota, and resource-stats.

### Alarms (read)

```bash
opendeploy monitoring alarms --json
opendeploy monitoring alarms project/<PROJECT_ID> --json
opendeploy monitoring alarms get <ALARM_ID> --json
opendeploy monitoring alarms history <ALARM_ID> --json
opendeploy monitoring alarms notes <ALARM_ID> --json
```

If the user has admin access:

```bash
opendeploy admin alarms --json
opendeploy admin alert-rules list --json
opendeploy admin alert-thresholds list --json
```

Summarize active alarms by severity, affected project/service/dependency, last
transition time, and likely next action. Do not reveal secret-bearing payloads.
If the user asks the agent to acknowledge, resolve, suppress, page support, or
post incident updates, hand off to `opendeploy-alarms`.

### Interpretation rules

- Build failures need build logs; runtime crashes need service/deployment runtime logs.
- If service config port, runtime `PORT`, and observed container/ingress port disagree, report the mismatch and hand off to `opendeploy-debug`; do not redeploy.
- If a dependency env hostname references a namespace suffix that differs from the project namespace, treat it as a platform/backend issue and report it with project/service/dependency IDs.
- For active incident triage, load `references/failure-playbook.md` after collecting IDs and logs.

---

## 2. Live-service operations (consent required)

Read first, then mutate, then verify.

```bash
opendeploy context resolve --json
opendeploy services get <service-id> --json
opendeploy deployments list --project <project-id> --service <service-id> --json
```

### Operations

```bash
opendeploy services restart <service-id> --confirm-live-service-change --json
opendeploy services stop <service-id> --confirm-live-service-change --json
opendeploy services start <service-id> --confirm-live-service-change --json
opendeploy services update <service-id> --cpu-limit 2 --memory-limit 4Gi --json
opendeploy services port-access enable <service-id> --json
opendeploy services port-access disable <service-id> --json

opendeploy deployments retry <deployment-id> --confirm-live-service-change --json
opendeploy deployments cancel <deployment-id> --confirm-live-service-change --json
opendeploy deployments restart <deployment-id> --confirm-live-service-change --json

opendeploy versions list --service <service-id> --json
opendeploy versions current --service <service-id> --json
opendeploy services versions rollback <project-id> <service-id> <version-id> --confirm-rollback --json
opendeploy versions promote <version-id> --confirm-promote --json
```

Rollback and promote are supported from the CLI when the global CLI is current
enough to expose `--confirm-rollback` / `--confirm-promote`. These flags send
the gateway-required `X-OpenDeploy-Consent: live_service_change` header. Do not
try body/query variants such as `confirm=true`; if a current CLI still receives
`consent_required`, stop and report a CLI/backend contract bug with the command,
version, and route.

Rollback has an extra success contract. A 200 response or message such as
`rollback successful` is not enough. The response must include a non-empty
`deployment_id` for the rollback deployment row. If `deployment_id` is missing,
treat the rollback as **not applied**, even if version flags changed in the DB.
Stop and report a backend false-success bug with the project, service,
version, response body, and the current `deployments list` result. Do not tell
the user rollback succeeded and do not retry blindly.

After a rollback response includes `deployment_id`:

```bash
opendeploy deploy wait <rollback-deployment-id> --follow --json
opendeploy deployments get <rollback-deployment-id> --json
opendeploy services get <service-id> --json
opendeploy services versions current <project-id> <service-id> --json
opendeploy deployments list --project <project-id> --service <service-id> --json
```

Only call the rollback complete when all are true:

- the rollback deployment exists in deployment history
- the rollback deployment reached a terminal successful/active state
- service read-back shows the target version/deployment is now live
- recent runtime health/log checks do not show the old version still running

If `versions.is_production` says the target is production but the service
record or deployment history still points at the old version, say the rollback
metadata changed but no rollout happened. This is an inconsistent platform
state, not a successful rollback.

### Consent gates

Ask before any of these because they affect live traffic or paid resources:

- `services restart` / `services stop` / `services start`
- `services update` resize (CPU / memory)
- `deployments cancel` / `deployments retry` during an incident
- `services versions rollback` / `versions promote`
- `services port-access enable/disable`

After every mutation:

1. Read back service status (`services get`, `services health`).
2. Read back deployment status (`deployments status`).
3. Sample recent runtime logs (`services logs --query tail=200`).

### Alarm lifecycle

Use `opendeploy-alarms` for:

- alarm notes and agent incident updates;
- `acknowledge`, `resolve`, `suppress` / `silence`;
- alarm-backed OpenDeploy support engagement and support check-in status;
- incident summaries for humans.

Use `opendeploy-oncall` for direct private Discord support-channel setup or
handoff when there is no alarm ID.

Do not call `DELETE` routes against `/v1/alarms/*` or `/v1/alert-rules/*` with
an `od_*` bearer token. For deletes, provide a dashboard handoff URL.

---

## 3. Cross-skill handoffs

| Symptom | Hand off to |
|---|---|
| Need to redeploy from local source | `opendeploy` (canonical autoplan) |
| Wrong port / 502 / `dial tcp timeout` | `opendeploy-debug` |
| DB / Redis not ready, `connection refused :5432` | `opendeploy-debug` |
| Build / runtime triage with logs | `opendeploy-debug` |
| Wrong build / start / root / Dockerfile path | `opendeploy-config` |
| Missing or wrong env var | `opendeploy-env` |
| Custom domain or DNS change | `opendeploy-domain` |
| CLI route missing but API exists | `opendeploy-api` |
| Alarm lifecycle, alarm-backed support engagement, or incident notes | `opendeploy-alarms` |
| Engage/contact OpenDeploy support with no alarm ID | `opendeploy-oncall` |

---

## 4. Notes

- This skill is read-only by default. The agent must not invent mutating commands beyond the list above.
- Never print env values, decrypted secret responses, bearer headers, bind signatures, or SSL private keys. Show key names only.
- See `references/security.md` for the full consent and redaction policy.
