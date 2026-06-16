# Startup Order And Dependency Readiness Reference

Do not fix dependency readiness by blind redeploy loops. Verify dependency
state, dependency env generation, service env injection, and application startup
behavior first.

## Commands

```bash
opendeploy dependencies status <project-id> --json
opendeploy dependencies env <project-id> --json
opendeploy services env get <project-id> <service-id> --json
opendeploy services logs <project-id> <service-id> --query tail=300
```

## Required Invariant

```text
dependency running
dependency env_vars present
service runtime env contains required DB/cache keys
service starts after dependency env is injected
```

If env is missing on the service, reconcile through `opendeploy-env`:

```bash
opendeploy services env reconcile <project-id> <service-id> --from-plan .opendeploy/plan.json --json
```

## App-Level Race

If the DB/cache is running and env is present but logs show the app connects too
early, patch the start command or application startup only with evidence.

Examples:

```bash
until nc -z $POSTGRES_HOST $POSTGRES_PORT; do sleep 1; done && node server.js
```

```bash
until nc -z $POSTGRES_HOST $POSTGRES_PORT; do sleep 1; done && npx prisma migrate deploy && node server.js
```

Patch via `opendeploy-config`, then redeploy through `opendeploy`.

## Dependency Not Ready

If `dependencies status` reports a non-running state, surface the platform
status to the user. Do not retry deploy. Wait for readiness with a sensible
timeout when the CLI supports it.

```bash
opendeploy dependencies wait <project-id> --json
```

## Platform Evidence

If an injected dependency hostname references a namespace suffix that differs
from the project namespace, report a platform/backend issue with project,
service, dependency, and deployment IDs. Do not keep redeploying.

