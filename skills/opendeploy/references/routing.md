# Universal OpenDeploy routing

The user-facing entrypoint is `/opendeploy ...` for every OpenDeploy task:
deploy, env, DB/cache, domain, logs, health, restart, rollback, alarms, oncall,
auth, setup, and updates. `/deploy` and `/od` are short aliases for
`/opendeploy deploy ...`.

When the user invokes `/opendeploy ...`, stay in the main `opendeploy` skill and
use this table as an internal handler map. Do not ask the user to re-run a
specialist slash command such as `/opendeploy-env` or `/opendeploy-ops`.
Specialist skills remain compatibility/debug entrypoints only.

| User intent / prompt after `/opendeploy` | Internal handler |
|---|---|
| `deploy this`, `host this`, `publish this`, `ship this`, `launch this`, `make it live`, `preview this`, `put this online`, `give me a live URL` | `opendeploy` |
| `/deploy` | `deploy` alias -> `opendeploy` |
| `/od` | `od` alias -> `opendeploy` |
| `install opendeploy`, `set up opendeploy`, `setup opendeploy`, `update opendeploy`, `upgrade opendeploy`, `activate opendeploy`, `check CLI`, `verify CLI`, `run doctor`, `npm install`, `npm latest`, `init project`, `stale CLI`, `stale plugin`, `doctor says update available` | `opendeploy-setup` |
| `login`, `log in`, `sign in`, `auth`, `auth status`, `whoami`, `token`, `OpenDeploy token`, `local deploy credential`, `guest credential`, `dashboard token`, `bind account`, `account binding link`, `401` | `opendeploy-auth` |
| `existing project`, `saved IDs`, `project id`, `service id`, `deployment id`, `same service`, `same project`, `resume deploy`, `what project is this`, `redeploy same service` | `opendeploy-context` |
| `upload env`, `.env upload`, `environment variables`, `config vars`, `secrets`, `import env`, `sync env`, `env diff`, `rotate secret`, `unset env`, `remove env`, `delete env var`, `set DATABASE_URL`, `AI Hub key`, `OpenAI key`, `Anthropic key`, `Gemini key`, `use OpenDeploy AI Hub` | `opendeploy-env` |
| `AI Hub`, `AI Hub credits`, `AI Hub balance`, `AI Hub usage`, `top up AI credits`, `auto-recharge`, `rotate AI Hub key`, `migrate to AI Hub`, `switch my OpenAI calls to AI Hub`, `consolidate LLM keys`, `one key across providers`, `OpenAI-compatible gateway`, `OPENDEPLOY_AI_API_KEY` | `opendeploy-ai-hub` |
| `database`, `db`, `cache`, `add postgres`, `add postgresql`, `add mysql`, `add redis`, `add mongodb`, `connection string`, `dependency health`, `DATABASE_URL`, `REDIS_URL`, `MONGODB_URI` | `opendeploy-database` |
| `monorepo`, `mono repo`, `workspace`, `pnpm workspace`, `turborepo`, `nx`, `docker-compose`, `compose`, `Procfile`, `multiple services`, `web and worker`, `worker`, `queue`, `cron`, `service split`, `root directory for app` | `opendeploy-monorepo` |
| `build command`, `start command`, `root directory`, `app directory`, `Dockerfile path`, `builder`, `auto-builder`, `health check`, `resources`, `memory`, `CPU`, `service config` | `opendeploy-config` |
| `domain`, `custom domain`, `hostname`, `custom hostname`, `subdomain`, `rename subdomain`, `DNS`, `CNAME`, `SSL`, `TLS`, `primary domain`, `verify domain` | `opendeploy-domain` |
| `why failed`, `show logs`, `logs`, `build logs`, `runtime logs`, `pod logs`, `container logs`, `debug deployment`, `diagnose deploy`, `CrashLoopBackOff`, `build failure`, `runtime crash`, `502`, `bad gateway`, `connection refused`, `dial tcp timeout`, `port mismatch`, `wrong port`, `PORT`, `Docker EXPOSE`, `traffic does not reach app`, `DB not ready`, `Redis not ready`, `startup order`, `readiness`, `wait for database`, `migration race`, `dependency DNS`, `svc.cluster.local`, `connection refused :5432` | `opendeploy-debug` |
| `health`, `status`, `uptime`, `metrics`, `CPU`, `memory`, `quota`, `service status`, `is it up`, `monitor`, `monitoring`, `circuit breaker`, `status page`, `restart`, `stop`, `start`, `rollback`, `roll back`, `resize`, `scale`, `change CPU`, `change memory`, `cancel deployment`, `retry deployment`, `recover service` | `opendeploy-ops` |
| `alert`, `alarm`, `incident`, `acknowledge alert`, `resolve alarm`, `silence alert`, `mute alert`, `suppress alarm`, `post incident update`, `alarm note`, `support check-in` | `opendeploy-alarms` |
| `oncall`, `Discord`, `loop in the OpenDeploy team`, `tell the OpenDeploy team`, `keep OpenDeploy responders updated`, `set up oncall`, `OpenDeploy oncall channel`, `post to oncall`, `engage support`, `contact OpenDeploy support`, `page OpenDeploy support`, `support packet`, dashboard "Set up oncall" prompt | `opendeploy-oncall` |
| `alert rule`, `threshold`, `notify me`, `notification` | `opendeploy-ops` |
| `CLI lacks route`, `missing CLI command`, `call OpenDeploy API`, `raw API`, `advanced API`, `API escape hatch`, `GET route`, `POST route`, `PUT route`, `PATCH route` | `opendeploy-api` |

## Alias behavior

`deploy` and `od` are only convenience aliases. They must not contain their own
deployment logic. They route to the canonical `opendeploy` autoplan workflow.

## Internal handoffs

- Missing auth -> use `opendeploy-auth` instructions internally.
- Saved IDs or redeploy intent -> use `opendeploy-context`.
- Local `.env` keys -> use `opendeploy-env` consent rules.
- DB/cache needs -> use `opendeploy-database`.
- Config mismatch -> use `opendeploy-config`.
- Port mismatch or dependency readiness issue -> use `opendeploy-debug`.
- Custom domain after deploy -> use `opendeploy-domain`.
- Failed deploy -> use `opendeploy-debug`.
- Health or live operations after deploy -> use `opendeploy-ops`.
- Alarm lifecycle, incident updates, or alarm-backed legacy support engagement -> use `opendeploy-alarms`.
- Discord/oncall conversation during alarm investigation or support engagement without an alarm -> use `opendeploy-oncall`; pair it with `opendeploy-alarms` only when acknowledge/resolve/suppress state must change.
- CLI/plugin update available -> use `opendeploy-setup`.
- CLI lacks a route but API exists -> use `opendeploy-api`.

User-facing wording should say "I'll handle that with OpenDeploy" rather than
"switch to opendeploy-xyz."
