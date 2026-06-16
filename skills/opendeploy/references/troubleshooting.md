# Troubleshooting

Use CLI-first diagnosis. Do not start by patching app code or retrying deploys
blindly.

## Basic inspection

```bash
opendeploy status --json
opendeploy deployments get <deployment-id> --json
opendeploy deployments logs <deployment-id> --query tail=300
opendeploy deployments build-logs <deployment-id> --follow
opendeploy services logs <project-id> <service-id> --query tail=300
```

If `status --json` reports gateway ok but a downstream circuit breaker is open,
the CLI is installed and reachable; that API area is degraded. Avoid mutating
calls that depend on the open service.

## High-signal failures

| Signal | Meaning | Next action |
|---|---|---|
| `npm view @opendeploydev/cli version` fails with `ENOTFOUND registry.npmjs.org`, `EAI_AGAIN`, timeout, or proxy/connect errors | npm registry path is blocked from the agent process, or the host has not granted network access | use `opendeploy-setup` -> "Agent Network / PATH / Proxy Repair"; retry once with approved network/escalated execution when available; do not keep reinstalling or switch to `npx` |
| `opendeploy: command not found` in the agent, but the user's terminal has `opendeploy` | GUI agent did not inherit the terminal PATH, or the CLI was installed into a prefix not visible to the agent | check `command -v opendeploy || true`, common absolute paths, and `npm prefix -g`; if the external terminal works, ask for `command -v opendeploy` and `echo "$PATH"`, then set `launchctl setenv PATH "<PATH_FROM_WORKING_TERMINAL>"` and restart the agent |
| `opendeploy status --json` / `preflight` fails with `fetch failed`, DNS, TLS, timeout, or proxy errors after the CLI is installed | the agent process cannot reach `https://dashboard.opendeploy.dev/api` | first rule out sandbox/network permission, then verify proxy env inside the agent; if needed, set GUI-process proxy variables with `launchctl setenv` and fully restart the agent |
| User's external terminal reaches npm/OpenDeploy but the agent does not | external terminal success proves the machine can reach the network, not that the agent can deploy | use the terminal result only as evidence; do not ask the user to install/deploy externally unless they explicitly choose manual deploy. Verify network, PATH, proxy, and gateway health inside the agent before any deploy mutation |
| Build failed | package/build command or missing build-time env | inspect build logs, fix cause, redeploy once |
| Runtime crash | app boot, runtime env, port, DB/DNS | inspect service logs and service env keys |
| Port mismatch | service config and runtime disagree | update service port or `PORT` env before retry |
| Missing DB env | dependency env not merged before service create | rerun env reconcile, verify, then deploy |
| Namespace suffix mismatch | generated dependency host does not match project namespace | report platform/backend issue with IDs |
| 403 quota/billing | resource cap or paid gate | ask user with `Upgrade plan (Recommended)` first; if chosen return `https://dashboard.opendeploy.dev/settings`; do not retry |
| 401 token rejected | auth file/token invalid | use auth recovery prompt; do not silently replace |
| 401 on read after successful write (same `od_a*` token) | gateway / downstream service rejected guest read of own resource (fixed in backend) | update backend; if still seen, surface binding URL from `auth guest` and ask user to bind |
| Live URL returns plain HTTP 403, service is active, runtime is `vite preview` | Vite preview rejected the public `*.opendeploy.site` Host header | ask before patching `vite.config.*` `preview.allowedHosts`, then re-upload and redeploy once |
| `logs diagnose` repeatedly returns `port_or_listener` across deploys | old CLI diagnoser only consulted runtime logs | update to `@opendeploydev/cli@0.1.6+` — `logs diagnose` now reads build logs and classifies `image_tag_invalid` / `image_push_failed` / `build_failed` / `build_node_modules_lost` before runtime symptoms |
| Build log shows `failed to push <registry>/:latest: invalid reference format` | image tag was fabricated from an empty input — the deployment was created with `source="manual"` and no `service_id` resolved a service. Backend fix landed; if still seen, the deploy was created against a missing service or with an empty `image_tag` request override | re-create the deployment with `service_id` set; do not retry under the same plan |
| `upload update-source` returns 400 complaining about `project_name` or `region_id` | old CLI without metadata flags | update to `@opendeploydev/cli@0.1.6+`, then rerun `upload update-source` with `--project-name <name> --region-id <region-id>`; do not use raw API for this known path |
| `upload update-source` returns 502 / 504 on a single archive that's > 100 MiB | gateway can't safely buffer that much body in memory; Cloudflare's ~100 s edge timeout also kicks in | switch to the chunked path (`/upload/multipart/init` → `/parts/N` → `/complete`) per `references/api-schemas.md` Step 4-MP. Do not retry the single-shot request |
| `POST /deployments` returns 409 with `source_status: "extracting"` and `Retry-After: 5` | source extraction worker is still unzipping the archive on the server; not a real failure | poll `GET /projects/:id` every 2-5 s until `source_status: "ready"`, then create the deployment. Typical wait is sub-minute even for 1 GiB archives |
| `POST /deployments` returns 422 with `extraction_error` set | source extraction failed on the server (corrupt ZIP, zip-slip path, file-system error) | re-upload the source archive. The previous staging file is gone; do not retry the deploy without a new upload |
| `complete` on a multipart session returns 409 with `missing_parts: [int, ...]` | one or more PUT `/parts/N` calls were dropped before reaching the server | re-PUT only the listed parts (not the whole archive), then re-issue `complete`. The session's `idempotency_key` lets the same `complete` call replay safely |
| `complete` returns 503 `Upload queue full, please retry shortly` | extractor worker queue saturated (genuine backpressure) | retry after 5-10 s. Do not loop tightly — the queue drains as workers finish in-flight extractions |

## Runtime preservation (static SPAs and similar)

> Note: this section was previously misapplied as the cause of every static-SPA
> deploy failure. The most common root cause was actually a malformed image
> tag (now fixed in the backend). Use the
> diagnostics below only after `logs diagnose` returns `build_node_modules_lost`
> or `runtime_dependency_missing` — that's the real signal.

The autodetect builder does not always carry `node_modules` from the build
stage to the runtime stage. Symptom: build succeeds, but the runtime
immediately fails because the start command (e.g. `bunx vite preview` or
`npx serve`) cannot find its binary at runtime.

Affected patterns observed in the wild:

- Vite + React + Bun static SPAs (no SSR) using `vite preview` as the start command.
- Astro / SvelteKit / Nuxt static export configurations that rely on `node_modules`
  at runtime to serve the built `dist/` output.
- Any project where the build output is `dist/` or `build/` static files but the
  start command is a node-based dev/preview server.

Fix options, in order of preference:

1. **Replace the start command with a static server that does not depend on `node_modules`.**
   For SPAs, copy `dist/` into a minimal nginx or `darkhttpd` image. Avoid
   `vite preview` in production — it is a dev-time helper.
2. **Use the project's existing root Dockerfile if it has one.** Patch the
   service to `--dockerfile-path Dockerfile` and verify logs show Dockerfile
   mode. If no Dockerfile exists and the source evidence clearly identifies a
   server runtime, add the minimal deployment files when file-edit permission is
   already granted; otherwise ask for structured source-edit approval and follow
   `references/dockerfile-authoring.md` instead of presenting Dockerfile work as
   a blocker.
3. **Switch to a runtime that bundles its own dependencies** (e.g. a single Bun
   binary that serves files) so no separate runtime install is needed.

If no Dockerfile exists, do not invent one from vague evidence. When evidence is
clear (language manifest, entrypoint, build command, start command, HTTP port),
you may offer "Add deployment files" as the OpenDeploy continuation and write a
minimal Dockerfile immediately when file-edit permission is already granted, or
after structured source-edit approval otherwise.

Example Dockerfile pattern to suggest after source-edit approval:

```dockerfile
# syntax=docker/dockerfile:1
FROM oven/bun:1 AS builder
WORKDIR /app
COPY package.json bun.lock* package-lock.json* ./
RUN bun install --frozen-lockfile || bun install
COPY . .
RUN bun run build

FROM node:20-alpine
WORKDIR /app
RUN npm i -g serve@14
COPY --from=builder /app/dist ./dist
ENV PORT=4173
EXPOSE 4173
CMD ["sh", "-c", "serve -s dist -l ${PORT}"]
```

After the user has added or approved a root `Dockerfile`, re-upload the source
and patch the service to use Dockerfile mode (`services config patch
<service-id> --dockerfile-path Dockerfile`). Do not use
`Dockerfile.opendeploy` for first deploy; current builders may ignore non-root
or alternate Dockerfile names and fall back to Railpack/autodetect.

## Final failure report

Return:

- status
- project ID
- service ID
- deployment ID
- last useful build/runtime log lines
- likely root cause
- next recommended action
