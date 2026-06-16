# Dockerfile authoring reference

Use this when the project has no usable Dockerfile and OpenDeploy autodetect
cannot produce a runnable service, but local source evidence clearly identifies
the runtime, entrypoint, HTTP port, build command, and start command.

Dockerfile authoring is a normal OpenDeploy path. Do not frame it as a reason to
leave OpenDeploy. Do not edit source until the user approves a structured
source-edit question that lists every file you will create or change.

## Preconditions

Before offering to generate deployment files, verify:

- language manifest exists (`go.mod`, `pyproject.toml`, `requirements.txt`,
  `package.json`, `Gemfile`, `composer.json`, `pom.xml`, `build.gradle`, etc.)
- entrypoint is known (`cmd/server/main.go`, `main.py`, `app.py`, `server.js`,
  `config.ru`, `artisan`, etc.)
- HTTP port is known or the app reads `PORT`
- required env keys are key-only listed
- no app source rewrite is needed

If any of these are unknown, ask a focused question instead of guessing.

## Files to create

Prefer the smallest deploy-specific surface:

- `Dockerfile` at source root
- `.dockerignore` if one is missing or unsafe

Do not create `Dockerfile.opendeploy` for first deploy. Current builders are
most reliable with source-root `Dockerfile`.

For multi-service plans that need more than one wrapper Dockerfile, use
included paths such as `Dockerfile.web`, `Dockerfile.worker`, or
`deploy/Dockerfile.worker`, then set `dockerfile_path` exactly to that path.
Do not place build-needed Dockerfiles under `.opendeploy/`, `.claude/`,
`.codex/`, or `.agents/`; smart archives exclude those metadata directories.

## General rules

- Use multi-stage builds for compiled languages.
- Copy dependency manifests first only when it is safe and obvious; otherwise
  keep the Dockerfile simple and correct.
- Do not bake secrets into `ENV`, `ARG`, labels, or files.
- Honor `$PORT` when the app supports it. Otherwise expose the app's real HTTP
  listener and set the service port to match.
- Use `CMD` for the final long-running server. Avoid relying on OpenDeploy
  `start_command` to override Dockerfile mode when migrations or shell chaining
  are required.
- For package-manager auto-builder services, first identify the package script
  the generated image actually runs. If it runs `start`, a source-approved
  package-script patch can be the smallest reliable way to add first-boot
  migrations; do not jump straight to a full Dockerfile when the script path is
  clear.
- If the image drops privileges or runs as a non-root user, set writable runtime
  locations in the image or entrypoint (`HOME`, `XDG_CACHE_HOME`, `TMPDIR`, and
  language-specific cache paths) and create/chown those directories. Avoid
  leaving `/root` as the runtime home for a non-root process.
- Check runtime version contracts before picking a base image: `.ruby-version`
  or `Gemfile` `ruby`, `package.json.engines`, `go.mod`, `pyproject`
  `requires-python`, and `composer.json` PHP constraints. Do not use a base tag
  that is clearly older than the app requires.
- Keep `.dockerignore` conservative: exclude `.git`, local dependency folders,
  local agent metadata (`.agents/`, `.claude/`, `.codex/`, `.gstack/`),
  non-source OpenDeploy local state (`.opendeploy/attempts/`,
  `.opendeploy/deploy-attempts.jsonl`, generated
  `.opendeploy/*credentials*.json` / `*secret*.json` / `*env*.json` files),
  build outputs, test caches, and secret files; include project-owned source
  directories even when they are named `build`, `scripts`, or `.npmrc` if the
  Dockerfile references them and they contain no credentials. This is
  `.dockerignore` guidance only. Do not add a blanket `.opendeploy/` entry to
  `.gitignore`; `.opendeploy/project.json` is shared team deployment context.
- After writing files, run local syntax checks when cheap (`dockerfile` parse is
  enough if Docker is unavailable), then re-run `opendeploy deploy plan . --json`
  and verify it selects Dockerfile mode.

## Go HTTP service

Use when `go.mod` exists and the entrypoint is known, such as
`cmd/server/main.go`.

```dockerfile
FROM golang:1.24-bookworm AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian12
WORKDIR /app
COPY --from=build /out/server /app/server
EXPOSE 8080
CMD ["/app/server"]
```

If the entrypoint is not `./cmd/server`, change only the final `go build`
package path. If the app defaults to 8080 but reads `PORT`, set the service port
to 8080 unless repo evidence says otherwise.

## Python HTTP service

Choose the server from source evidence:

- FastAPI/ASGI -> `uvicorn module:app --host 0.0.0.0 --port ${PORT:-8080}`
- Flask/WSGI -> `gunicorn --bind 0.0.0.0:${PORT:-8080} module:app`
- Django -> include migrations only with user approval and a fresh managed DB

Use `python:3.x-slim`, install from `requirements.txt` or `pyproject.toml`, and
avoid copying local `.venv`.

## Node.js service

Use the package manager from the lockfile or `packageManager`. Pin Corepack to
the repo-declared version when present. For static Vite/SPA projects, prefer a
small static server image only when the output directory and SPA fallback are
known.

## Prebuilt-image wrapper

Use when source evidence says the app is intended to run from a published image
and OpenDeploy image-service creation is not available in the current CLI.

```dockerfile
FROM vendor/app:tag
```

For a worker that does not listen on HTTP but needs a readiness endpoint on the
current platform, ask before adding a tiny health shim. The shim must start the
real worker as the main child process and exit when the worker exits; it is not
a substitute for fixing a crashing worker.

## Ruby / Rails

Use the repo's `Gemfile.lock` Ruby version when available. Plan database
migrations before first traffic. Prefer a Dockerfile `CMD` wrapper for
`bundle exec rails db:prepare && bundle exec puma ...` because service
`start_command` overrides may not execute in Dockerfile mode.

## PHP / Laravel

Load `dockerfile-php-laravel.md` for the Nginx + PHP-FPM pattern and extension
selection. Do not hard-code a previous project's extensions; derive them from
`composer.json`, framework docs, and runtime errors.

## User question shape

```text
question: "OpenDeploy needs deployment files for this service. Proceed?"
options:
  - label: "Add Dockerfile and deploy (Recommended)"
    description: "I will create Dockerfile and .dockerignore from the detected runtime, then deploy with Dockerfile mode."
  - label: "Review files first"
    description: "Show the exact Dockerfile and .dockerignore plan before editing."
  - label: "Use manual config"
    description: "Try explicit build/start/port config without changing source files."
  - label: "Pause"
    description: "Stop before editing files, creating resources, or uploading source."
```

Make "Add Dockerfile and deploy" recommended only when the runtime evidence is
clear and autodetect cannot deploy the service.
