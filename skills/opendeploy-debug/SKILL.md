---
name: opendeploy-debug
version: "0.0.20"
description: Single OpenDeploy debugging entrypoint for failed or unreachable deployments. Use when the user says logs, show logs, build logs, runtime logs, failed deployment, why failed, diagnose deploy, debug deployment, 502, bad gateway, connection refused, dial tcp timeout, CrashLoopBackOff, build failure, runtime crash, port mismatch, wrong port, Docker EXPOSE mismatch, DB not ready, Redis not ready, startup order, readiness, dependency DNS, DATABASE_URL missing, REDIS_URL missing, dependency env missing, or service starts before managed DB/cache is ready.
user-invokable: true
---

# OpenDeploy Debug

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

Use this as the single entrypoint for failed, crashing, or unreachable
OpenDeploy deployments. Start read-only, collect evidence, classify the failure,
then hand off to the narrow mutation skill only after there is a concrete cause.

## Decision Tree

1. Resolve IDs from the user's pasted URL, local context, or CLI context.
2. Read deployment and service state.
3. If the build failed, collect build logs first.
4. If the app is active but unreachable or crashing, collect runtime logs.
5. Compare service config, runtime env, exposed port, and log evidence.
6. Check managed dependency status and injected env keys when DB/cache is in the
   app, plan, or error logs.
7. Classify the issue with the stable category keys below, update the local
   deploy-attempt record when a worktree/context exists, then choose the next
   action.

## Baseline Evidence

Run only the commands needed for the available IDs:

```bash
opendeploy context resolve --json
opendeploy deployments get <deployment-id> --json
opendeploy deployments status <deployment-id> --json
opendeploy deployments logs <deployment-id> --query tail=300
opendeploy deployments build-logs <deployment-id> --follow
opendeploy services get <service-id> --json
opendeploy services config get <service-id> --json
opendeploy services env get <project-id> <service-id> --json
opendeploy services logs <project-id> <service-id> --query tail=300
opendeploy dependencies status <project-id> --json
```

If the CLI exposes structured diagnosis for the deployment, use it as one input,
not as the only source of truth:

```bash
opendeploy logs diagnose <deployment-id> --json
```

## Classification

| Evidence | Classification | Next action |
|---|---|---|
| Build phase failed, package install error, missing build command, or compiler error | `build_command` | Summarize build log evidence; use `opendeploy-config` only if config is wrong, otherwise ask before app-code edits |
| Service is running but proxy returns 502, connection refused, wrong listener, Docker `EXPOSE` disagreement, or runtime listens on a different port | `port_mismatch` | Load `references/port.md`; patch through `opendeploy-config` only with evidence |
| DB/cache status is not running, service env lacks dependency keys, DNS hostname has wrong namespace, or logs show dependency connection refused | `dependency_env` | Load `references/startup-order.md`; use `opendeploy-database` or `opendeploy-env` for resource/env fixes |
| Runtime logs show missing env key unrelated to managed dependency | `missing_env` | Use `opendeploy-env`; show key names only |
| Service is active, health path is 200, but a primary app endpoint returns 5xx and logs mention missing DB tables, unapplied migrations, migration files, or ORM relation errors | `migration_missing` | Patch the service start command or use the platform one-off command when available, then redeploy/restart once with consent |
| User asks to inspect DB data/table state and the DB is an OpenDeploy managed dependency | `unknown` unless this explains a deploy failure | Hand off to `opendeploy-database` and use temporary dependency port access/query. Do not recommend adding an app debug endpoint or redeploy unless DB port access and exec are unavailable and the user approves a source edit |
| Gateway status is ok but a downstream breaker is open, dependency hostname namespace is impossible, or logs are unavailable despite valid IDs | `platform_backend` | Use `opendeploy-ops` for health; report IDs and evidence |
| Evidence is incomplete or contradictory | unknown | Stop and report collected evidence plus the missing signal |

For categories not represented in this short table, load
`../opendeploy/references/deploy-attempt-record.md` and choose the closest
stable category (`analysis_miss`, `source_archive`, `quota`, `edge_ingress`,
`service_mapping`, etc.). Do not invent project-specific category names.

## Deploy Attempt Record

When debugging from a local worktree or resolvable `.opendeploy` context, update
the latest `.opendeploy/attempts/...json` record before any retry, handoff, or
terminal report. If no record exists, create a minimal one using
`../opendeploy/references/deploy-attempt-record.md`. Store deployment IDs,
service IDs, status, redacted log excerpts, `error_category`, root cause,
planned fix, and redeploy result. Store env key names only.

## Hard Rules

- Do not retry a failed deploy until the root cause is identified and something
  concrete changed.
- Do not create or edit Dockerfiles, package scripts, start commands, or
  application code without log or config evidence and explicit user approval.
- Do not print env values, API keys, bearer headers, bind signatures, decrypted
  secrets, or SSL private keys. Show key names only.
- If deployment/log/build-log reads return 401 or 403, stop debugging and hand
  off to `opendeploy-auth`; do not infer build or runtime causes from missing
  logs.
- If the fix is a service config, env, DB/cache, or domain mutation, hand off to
  the matching skill and then redeploy through `opendeploy`.
- If dependency hostnames reference a namespace that does not match the project,
  treat it as platform/backend evidence. Do not keep redeploying.

## References

- `references/logs.md` - log collection and generic triage.
- `references/port.md` - port mismatch checks and fixes.
- `references/startup-order.md` - managed DB/cache readiness and env injection.
- `../opendeploy/references/deploy-attempt-record.md` - local attempt record schema, stable error categories, and redaction rules.
