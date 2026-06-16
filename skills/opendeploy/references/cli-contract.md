# CLI contract

OpenDeploy skills execute through the official npm package
`@opendeploydev/cli`. The CLI owns deterministic primitives: API calls, local
analysis, archive creation, secret redaction, read-back verification, and
consent resumability. The agent owns the dynamic workflow loop and adjusts the
plan after each structured CLI result.

## Package identity

Expected metadata:

```text
name: @opendeploydev/cli
repository: https://github.com/opendeploy-dev/opendeploy-cli
license: MIT
security contact: security@opendeploy.dev
```

Verify when trust matters:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy preflight . --json
```

The npm commands are the global CLI version gate. They catch stale global
installs before the agent trusts `opendeploy preflight`. Run them sequentially
enough that `npm list -g` returning nonzero for an uninstalled package is
handled as `cli_missing`, not a failed or suspicious install. Continue to
`npm view`, ask one setup approval for `npm install -g
@opendeploydev/cli@latest`, then verify and run `preflight`. `preflight` then
returns OpenDeploy skill-plugin version status, auth state, saved context,
gateway health, and a read-only deploy plan summary in one JSON object. Do not
run separate `--version`, `auth status`, `context resolve`, `jq`, or raw `curl`
plugin probes as the default preamble.

Default to the global `opendeploy` command. If global is missing or stale, ask
once whether to install/update `@opendeploydev/cli@latest`; if the user skips
the update, continue with the installed global CLI when it supports the required
commands. If the installed global CLI is too old for a required mutation, stop
before mutation. Do not mix `npx` and global inside one deploy, and do not use
`npx @opendeploydev/cli` as a fallback after a skipped global update.

## JSON-first rules

- Use `--json` for every machine-consumed command.
- CLI output must redact secrets by default. Env containers keep key names and
  redact every value by default; other output redacts only sensitive field
  names.
- `--show-secrets` is allowed only after an explicit user request to reveal
  values.
- Mutating commands must return enough IDs for read-back verification.
- Errors must include `error_code`, `message`, `retryable`, and `next_action`.

## Error codes

This is the **target** shape the agent expects. The gateway emits the
unified envelope directly for its own error sites (auth, agent-delete-guard,
agent-tier, callback signature, consent gate); for downstream-service errors,
the backend still returns a mix of `{error: "...", message: "..."}` plus a few
specific codes. The CLI translates downstream errors into the codes below;
everything else surfaces as `error_code: "unknown"` with the original payload
preserved.

Gateway-emitted envelopes carry, in addition to the legacy `error` and
`message` keys:

```json
{
  "error":       "<legacy short string>",
  "error_code":  "<closed-set machine code>",
  "message":     "<human readable text>",
  "retryable":   false,
  "next_action": "<short hint, e.g. ask_user, dashboard_handoff, bind_account, fix_call>"
}
```

Agents should prefer `error_code` over `error` for routing decisions; the
legacy `error` key is retained for back-compat with older CLI/dashboard code.

Agents pattern-match against this closed set. An unknown code means stop and
report rather than retry.

| Code | Backend signal today | Retryable | Typical next action |
|---|---|---|---|
| `auth_missing` | local: no auth file / token | no | use the auth playbook |
| `auth_invalid` | HTTP 401 | no | re-auth via `opendeploy-auth`; never silently delete the file |
| `auth_forbidden` | HTTP 403 (not bind_required) | no | ask user; do not retry |
| `bind_required` | `{error: "bind_required"}` | no | print the dashboard binding URL; ask user to bind |
| `consent_required` | local: missing `--confirm-*` flag | n/a | ask user, resume with the CLI-returned `resume_command` |
| `quota_exceeded` | `{error, exceeded_resources:[{resource_type,current,requested,limit,unit}], available_addons:[{display_name,resource_type,quantity,unit,price,currency}]}` | no | backend has already calculated effective plan + add-on quota. Report each resource (`storage`, `cpu`, `memory`, `replicas`, `projects/services/domains`, `deployments/daily_deployments`, `bandwidth/data_transfer`) with current/requested/limit; name matching add-on quantity/price when present; ask with Upgrade plan/add-on (Recommended); if chosen return `https://dashboard.opendeploy.dev/settings`; don't retry |
| `guest_quota_exceeded` | `{error: "guest_quota_exceeded", field, requested, limit}` | no | report the field (`cpu_limit`, `cpu_request`, `memory_limit`, `memory_request`, `replicas`) and values; recommend plan upgrade; if chosen return `https://dashboard.opendeploy.dev/settings`; otherwise shrink only that field |
| `subscription_required` | `{error: "subscription_required"}` | no | recommend plan upgrade; if chosen return `https://dashboard.opendeploy.dev/settings` |
| `rate_limited` | HTTP 429 | yes | back off, then retry once |
| `gateway_unreachable` | network / DNS error | yes | retry once; if still failing, report and stop |
| `gateway_degraded` | `status --json` shows downstream breaker `open` | yes after recovery | wait or use the ops playbook |
| `not_implemented` | CLI returns `{status: "not_implemented"}` (e.g. `deploy step` for unsupported step) | no | fall back to the resource commands listed in `references/cli.md` |
| `invalid_input` | HTTP 400 | no | fix the call; do not loop |
| `not_found` | HTTP 404 | no | re-resolve context |
| `conflict` | HTTP 409 (e.g. duplicate subdomain) | no | ask user how to proceed |
| `port_mismatch` | log diagnose result | no | use the debug playbook |
| `dependency_not_ready` | `dependencies status` non-running | yes after wait | poll via `dependencies wait` |
| `dependency_env_missing` | missing env in `services env get` | no | use the env or debug playbook |
| `namespace_mismatch` | hostname suffix mismatch in injected env | no | report platform/backend issue with IDs; do not retry |
| `build_failed` | deployment status `failed` from build phase | no | inspect build logs, fix cause, redeploy once |
| `runtime_crash` | deployment status `crashed` or service unhealthy | no | inspect runtime logs |
| `destructive_blocked` | local: skill refuses DELETE with `od_*` | no | provide dashboard URL, stop |

Recoverable problems should also return `status=needs_adjustment` with a
concrete `next_action` so the agent updates the plan and resumes from the same
step rather than restarting.

Until the backend ships a unified envelope, treat the CLI's translated
`error_code` as authoritative.

## Consent required

There are two layers of consent:

1. **CLI-side (always on).** The CLI inspects the user's `--confirm-*` flags
   locally and, when missing, returns the `consent_required` envelope below
   without making the network call. This is the day-one contract every agent
   has worked against.

2. **Gateway-side ConsentGate (default-on).** Selected high-risk routes
   (custom-domain bind, paid checkout, security-sensitive uploads, rollback,
   promote, restart, stop, start, retry/cancel) reject
   requests authenticated with `od_*` bearer tokens unless the caller sends
   the `X-OpenDeploy-Consent: <kind>` header. Defense in depth — even a
   misbehaving agent that skips the CLI's local gate gets blocked before
   the request reaches the downstream service. OIDC dashboard sessions are
   never affected. The gate is on by default;
   `OPENDEPLOY_CONSENT_GATE_DISABLED=1` is an emergency escape hatch only.

   Header convention (comma-separated for multiple kinds):
   ```text
   X-OpenDeploy-Consent: paid,custom_domain
   ```

   The CLI sends the header automatically when the user supplied the
   matching `--confirm-*` flag. If the gateway returns 403 with
   `error_code: "consent_required"` despite the CLI sending the header,
   the agent should treat it as a contract violation and stop rather than
   silently retrying.

When user approval is needed, the CLI should return:

```json
{
  "status": "consent_required",
  "kind": "env_upload",
  "message": "OpenDeploy needs approval before uploading env values.",
  "keys": ["DATABASE_URL", "REDIS_URL"],
  "values_redacted": true,
  "resume_command": "opendeploy deploy step --plan .opendeploy/plan.json --step services --confirm-env-upload"
}
```

Supported `kind` values:

```text
guest_credential
env_upload
paid
destructive
custom_domain
security_sensitive
live_service_change
```

`paid` is never expected on a normal first deploy. Agents should mention paid
approval only when the CLI/gateway returns a concrete quota/add-on/billing gate
or when the user explicitly requested a paid resource.

Friendly CLI flags map to these kinds:

```text
--confirm-guest-credential      -> guest_credential
--confirm-env-upload            -> env_upload
--confirm-paid                  -> paid
--confirm-custom-domain         -> custom_domain
--confirm-security-sensitive    -> security_sensitive
--confirm-destructive           -> destructive
--confirm-live-service-change   -> live_service_change
--confirm-restart               -> live_service_change
--confirm-rollback              -> live_service_change
--confirm-promote               -> live_service_change
```

Agent behavior:

1. Stop on `status=consent_required`.
2. Ask the user using the CLI-provided `message`, key/resource list, and risk
   type through the host agent's structured `AskUserQuestion` / approval UI
   when available. Do not print a manual "Reply with one of..." menu except as
   a last-resort fallback.
3. Resume only with the exact `resume_command` from the CLI.
4. If the user declines, stop without mutation.

## Dynamic workflow contract

Current first-deploy flow:

```bash
opendeploy preflight . --json
opendeploy deploy plan . --json
# Mutations currently use the resource-command sequence in references/cli.md:
# auth status/guest -> regions list -> projects create -> dependencies create/status
# -> services create/env reconcile -> upload update-source --project-name ... --region-id ... -> deployments create/get
# -> domains list/update-subdomain -> deploy report.
opendeploy deploy report <deployment-id> --json
```

`deploy step` and `deploy apply` are forward-compatible dispatcher commands.
Use them only when the installed CLI returns executable `next_action` commands
for the required steps. If a step returns `status=not_implemented`, switch to
the resource-command sequence above instead of restarting from scratch.

When the step dispatcher is available, every mutating step should return:

```json
{
  "status": "ok",
  "step": "dependencies",
  "created_ids": {"postgres": "dep_..."},
  "outputs": {"env_keys": ["DATABASE_URL"]},
  "verification": {
    "required": true,
    "command": "opendeploy deploy verify --plan .opendeploy/plan.json --after dependencies --json"
  },
  "next_action": {
    "kind": "continue",
    "command": "opendeploy deploy step --plan .opendeploy/plan.json --step services --json"
  }
}
```

Recoverable problems should return `status=needs_adjustment` with a concrete
`next_action`; the agent updates the plan or asks the user, then resumes from
the same step. Do not force a restart from scratch.

`deploy apply` is a convenience runner that executes until the next stop gate
and returns the same structured step result. It is not an opaque all-in-one
black box, and it is not required for the current resource-command path.

Resource-level commands the agent can mix in when bypassing the plan loop
(e.g. for redeploy of an existing service, or for narrow diagnostics):

```bash
opendeploy context resolve --json
opendeploy auth status --json
opendeploy regions list --json
opendeploy projects create ... --json
opendeploy dependencies create ... --json
opendeploy dependencies status <project-id> --json
opendeploy dependencies wait <project-id> --json
opendeploy dependencies env <project-id> --json
opendeploy services create <project-id> --body service.json --json
opendeploy services env reconcile <project-id> <service-id> --from-plan .opendeploy/plan.json --json
opendeploy services config get <service-id> --json
opendeploy services config patch <service-id> --port <port> --json
opendeploy upload update-source <project-id> <path> --project-name <name> --region-id <region-id> --json
opendeploy deployments create --project <id> --service <id> --json
opendeploy domains list --service <service-id> --type auto --json
opendeploy domains update-subdomain <domain-id> --subdomain <prefix> --json
opendeploy logs diagnose <deployment-id> --json
```

`services create` is not fire-and-forget. It must read back the service and
return `verification.ok`. If the backend drops `port`, `port_locked`,
`start_command`, or `build_command`, the CLI may patch once with the same
requested values and read back again. Agents must not create deployments when
`verification.ok` is false.

## Final deploy report

Successful first deploy should end with:

```json
{
  "status": "active",
  "bind_url": "https://dashboard.opendeploy.dev/guest/...",
  "project_id": "uuid",
  "service_id": "uuid",
  "deployment_id": "uuid"
}
```

For unbound guest deploys, print only the signed bind URL in the user-facing
final answer. Do not print `live_url`, app URL, health URL, or IDs. Keep
`live_url` internal for smoke tests, late-bound env patches, and bind-link
construction. Account-bound deploys may print the live URL plus dashboard URL.
