# Debug Logs Reference

Start read-only. Collect enough evidence to decide whether the failure is build,
runtime, port, dependency, env, quota, auth, or platform-related.

## Commands

```bash
opendeploy deployments get <deployment-id> --json
opendeploy deployments status <deployment-id> --json
opendeploy deployments logs <deployment-id> --query tail=300
opendeploy deployments build-logs <deployment-id> --follow
opendeploy services logs <project-id> <service-id> --query tail=300
opendeploy logs diagnose <deployment-id> --json
```

## Checks Before Redeploy

- Build command, package manager, dependency install, or compiler failure.
- Runtime env key missing. Show key names only.
- Service configured port vs runtime listener vs `PORT` env.
- Managed dependency env missing from the service.
- Managed dependency hostname namespace mismatch.
- Quota, subscription, circuit breaker, or route availability issue.
- Auth scope issue: 401/403 when trying to read deployment, build logs, or
  runtime logs.

## Reporting

Report the deployment ID, project ID, service ID, status, failed phase, the
shortest relevant log excerpt, and the specific next action. If the evidence is
missing or contradictory, say which signal is missing and stop.

