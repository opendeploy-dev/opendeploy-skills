# Port Mismatch Reference

Port mismatch is common when the configured service port, runtime listener,
`PORT` env, Dockerfile, and logs disagree. Diagnose before redeploying.

## Commands

```bash
opendeploy services config get <service-id> --json
opendeploy services env get <project-id> <service-id> --json
opendeploy services logs <project-id> <service-id> --query tail=300
opendeploy logs diagnose <deployment-id> --json
```

## Sources To Compare

| Source | Where to read |
|---|---|
| Planned service port | `.opendeploy/plan.json` or deploy plan output |
| OpenDeploy service config | `services config get <service-id> --json` -> `.port` |
| Dockerfile | `EXPOSE` directive |
| docker-compose | `ports:` block container side |
| Runtime env | `PORT` on the service |
| Runtime logs | `listening on`, `server started`, `bind`, or framework startup lines |

## Common Mismatches

| Service config | Container reality | Fix |
|---|---|---|
| `3000` | nginx/static server on `80` | Patch service port to `80` |
| `80` | app on `3000` | Patch service port to `3000` |
| Any port | app ignores `$PORT` env | Patch start command or app config with evidence |
| Any port | headless worker, no listener | Remove HTTP route or add a health server |

## Fix

Patch narrowly through `opendeploy-config`, read back config, then redeploy
through the canonical `opendeploy` workflow.

```bash
opendeploy services config patch <service-id> --port <port> --json
opendeploy services config get <service-id> --json
```

Do not guess a framework default when explicit project evidence disagrees.

