# OpenDeploy Agent Skills

OpenDeploy skills let AI coding agents deploy, monitor, debug, and operate apps on [OpenDeploy](https://opendeploy.dev).

OpenDeploy is the agent-first deployment platform: agents can take local source code to a live hosted app with a free first deploy, no payment method, and no account required before the first successful guest deploy.

## Install

Install the OpenDeploy skills with the standard Agent Skills installer:

```sh
npx -y skills add opendeploy-dev/opendeploy-skills --skill '*'
```

The installer supports the same agent targets as the Agent Skills ecosystem, including Claude Code, Codex, Cursor, OpenCode, OpenClaw, Windsurf, and more.

When the installer asks for installation scope, Global is recommended for most users because OpenDeploy then works across all projects. Project installation is useful when a team wants to commit shared skills into a repository.

## Use

After installation, ask your agent:

```text
Use OpenDeploy to deploy this project.
```

You can also use the short entrypoints when your agent supports slash-style skill invocation:

```text
/opendeploy
/deploy
/od
```

## Install Everywhere

Install all OpenDeploy skills globally for every supported agent on the machine:

```sh
npx -y skills add opendeploy-dev/opendeploy-skills -g --all
```

## Update

Update globally installed skills:

```sh
npx -y skills update -g
```

Update project-installed skills:

```sh
npx -y skills update -p
```

## What First Deploy Does

The first OpenDeploy deploy is free:

- no account is required before deployment
- no payment method is required
- a successful guest deployment returns a bind link
- binding keeps the project after the guest window and opens the dashboard

The skills install does not deploy anything by itself. Deployment starts only after the user asks the agent to deploy with OpenDeploy.

## Security Model

Installing these skills only installs Markdown instructions for your agent. It
does not create an OpenDeploy project, upload source code, create credentials,
write environment variables, or start billing.

The skills use the official global `opendeploy` CLI for OpenDeploy actions.
They are written to ask before credential creation, real environment-variable
upload, paid AI Hub credit changes, destructive actions, or live-service
mutations. First deploy runs on OpenDeploy's free tier and creates no account,
payment method, or charge. If a concrete quota or add-on gate appears later,
the agent stops and asks separately.

## Included Skills

| Skill | Purpose |
| --- | --- |
| `opendeploy` | Canonical deploy, redeploy, debug, and operate entrypoint. |
| `deploy` | Short alias for `opendeploy`. |
| `od` | Shortest alias for `opendeploy`. |
| `opendeploy-setup` | Install, update, verify, and repair OpenDeploy CLI and skill setup. |
| `opendeploy-auth` | Manage OpenDeploy deploy credentials and binding state. |
| `opendeploy-context` | Resolve, save, or inspect project/service/deployment context. |
| `opendeploy-config` | Inspect and patch service configuration. |
| `opendeploy-env` | Scan, upload, patch, rotate, and reconcile environment variables. |
| `opendeploy-database` | Plan, create, wait for, and diagnose managed databases. |
| `opendeploy-volume` | Plan and manage persistent OpenDeploy volumes. |
| `opendeploy-domain` | Manage auto subdomains, custom domains, DNS, and SSL. |
| `opendeploy-monorepo` | Plan monorepo and multi-service deployments. |
| `opendeploy-debug` | Triage failed builds, runtime crashes, logs, ports, health checks, and rollout issues. |
| `opendeploy-ops` | Monitor, restart, stop, start, rollback, and operate live services. |
| `opendeploy-alarms` | Manage alarms and incident state. |
| `opendeploy-oncall` | Get help from OpenDeploy staff when deployment or platform issues block progress. |
| `opendeploy-ai-hub` | Detect, provision, and manage OpenDeploy AI API keys and model usage. |
| `opendeploy-api` | Safe escape hatch for supported OpenDeploy API routes not yet exposed by the CLI. |

## Native Plugins

This repository is the universal skills distribution for many agents. Native plugin repositories can still provide deeper host-specific integration:

- Claude Code: `opendeploy-dev/opendeploy-claude-plugin`
- Codex: `opendeploy-dev/opendeploy-codex-plugin`
- Cursor: `opendeploy-dev/opendeploy-cursor-plugin`
- OpenClaw: `opendeploy-dev/opendeploy-openclaw-plugin`

Use this repository when you want one standard `npx skills add` path. Use native plugins when you specifically want that host's plugin installation and update flow.

## Development

Validate the package before publishing:

```sh
./scripts/validate.sh
```

## License

MIT
