---
name: opendeploy-config
version: "0.0.20"
description: Inspect or patch OpenDeploy service config such as build command, start command, root directory, Dockerfile path, builder, port, resources, healthcheck, and monorepo settings. Use when the user says build command, start command, root directory, app directory, Dockerfile, builder, auto-builder, health check, resources, memory, CPU, port config, monorepo config, or auto-detection picked the wrong build/start/root/port.
user-invokable: true
---

# OpenDeploy Config

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

```bash
opendeploy services config get <service-id> --json
```

Patch narrowly:

```bash
opendeploy services config patch <service-id> --port 2368 --json
opendeploy services config patch <service-id> --build-command "pnpm build" --json
opendeploy services config patch <service-id> --start-command "pnpm start" --json
opendeploy services config patch <service-id> --root-directory "./apps/web" --json
opendeploy services config patch <service-id> --dockerfile-path "./Dockerfile" --json
```

After patching, read back config and decide whether restart or redeploy is
needed. Prefer narrow patches over recreating services. For port-specific
triage, hand off to `opendeploy-debug`.

Dockerfile mode reliability rule:

- Use Dockerfile mode when the project already has a source-root `Dockerfile`.
- If no Dockerfile exists and OpenDeploy autodetect cannot produce a runnable
  service, Dockerfile authoring is allowed after explicit structured source-edit
  approval. This is a positive OpenDeploy path, not a failure: show the exact
  files to add first, then write a minimal source-root `Dockerfile` and
  `.dockerignore` derived from repo evidence.
- Do not set `dockerfile_path` to `Dockerfile.opendeploy` for first deploy.
- If the repo only has a nested Dockerfile such as `docker/Dockerfile`, ask the
  user before changing source root or copying/renaming it.
- Read-back config is necessary but not sufficient; the next build logs must
  show Dockerfile mode rather than Railpack/autodetect.
- Generated Dockerfiles should avoid secrets, avoid broad app rewrites, honor
  `$PORT` when the framework supports it, and `EXPOSE` the HTTP listener.

Port and persistence rules:

- When Dockerfile or compose exposes multiple ports, patch the service to the
  HTTP listener. Do not pick SSH/SMTP/raw TCP ports for OpenDeploy HTTP
  ingress.
- If the app declares persistent data paths but OpenDeploy exposes no
  storage/volume route, ask for the OpenDeploy storage strategy before
  proceeding: configure object-storage/media env, continue with local file
  paths and a clear persistence note, or review details.
- Do not set installer-lock/setup-complete flags unless an admin/bootstrap
  plan exists or the user explicitly approves that setup choice.
