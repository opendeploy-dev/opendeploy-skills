---
name: opendeploy-alarms
version: "0.0.20"
description: Manage OpenDeploy alarm lifecycle from an agent. Use for active alarms, alert history, alarm notes, acknowledging, resolving, suppressing, alarm-backed legacy support engagement, and human-visible dashboard updates. Use opendeploy-oncall for Discord oncall setup, direct support channel handoff when no alarm exists, and per-alarm conversation with OpenDeploy responders.
allowed-tools:
  - AskUserQuestion
  - Read
  - Bash(npm:*)
  - Bash(opendeploy:*)
  - Bash(jq:*)
user-invokable: true
---

# OpenDeploy Alarms

This skill lets the agent manage alarms as an incident operator while keeping
the human in the loop and leaving an audit trail inside OpenDeploy.

## Invocation Preflight

If this skill is invoked directly, first run
the global CLI version gate unless another OpenDeploy skill already did:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy preflight . --json
```

The npm commands are mandatory before alarm mutations. They catch stale global
installs such as `@opendeploydev/cli@0.1.0` even when that old binary cannot
accurately report its own update status. If the installed global CLI is older
than npm latest, hand off to `opendeploy-setup` and ask via structured
`AskUserQuestion` whether to update global or skip and continue. If the user
skips, continue with the installed global CLI only for command families it
actually supports.

Use the global `opendeploy` command for both checks and execution. Do not probe
with `npx` and then mutate with global `opendeploy`; the checked binary and the
executing binary must be the same.

Alarm lifecycle commands require `@opendeploydev/cli` with named alarm routes.
If the CLI is older, use `opendeploy-setup` before mutating. Do not use raw API
for alarm actions unless the user explicitly approves the escape hatch.

## Mental Model

OpenDeploy is agent-first, but incidents still need human observability:

- The agent investigates and can take bounded lifecycle actions.
- The human sees what happened through alarm notes, history, and final summary.
- Discord oncall conversation and direct private support-channel setup are
  handled by `opendeploy-oncall`; this skill handles alarm lifecycle and
  dashboard-visible notes.
- Legacy OpenDeploy support engagement is alarm-backed. Use it only after
  explicit user consent and only when an alarm ID exists. If the user asks to
  engage/contact/page OpenDeploy support but there is no alarm, hand off to
  `opendeploy-oncall` to return the private Discord channel URL.
- Every support request includes the agent's evidence packet, not just "help".
- OpenDeploy support check-in is a staff action. The agent may report whether
  support checked in, but must not mark support as checked in unless it is
  authenticated as OpenDeploy staff/admin.

## Read First

Resolve an alarm from a pasted dashboard URL, alarm ID, project ID, or local
context. Start with read-only commands:

```bash
opendeploy monitoring alarms --json
opendeploy monitoring alarms project/<PROJECT_ID> --json
opendeploy monitoring alarms get <ALARM_ID> --json
opendeploy monitoring alarms history <ALARM_ID> --json
opendeploy monitoring alarms notes <ALARM_ID> --json
```

Then gather only the relevant evidence:

```bash
opendeploy services health <SERVICE_ID> --json
opendeploy services logs <PROJECT_ID> <SERVICE_ID> --query tail=300
opendeploy deployments list --project <PROJECT_ID> --service <SERVICE_ID> --json
opendeploy monitoring project-health <PROJECT_ID> --json
opendeploy monitoring dependency-health <PROJECT_ID> --json
```

Summarize severity, affected service/dependency, first/last occurrence, current
state, likely cause, and next safe action. Never print secrets.

## Human-Observable Updates

Before any lifecycle mutation, post a concise alarm note so the dashboard shows
what the agent is doing:

```bash
opendeploy monitoring alarms note <ALARM_ID> \
  --note-type note \
  --text "Agent investigating: <symptom>; evidence: <short redacted evidence>; next: <action>." \
  --json
```

Post another note after the action with the result. For long incidents, post a
new note whenever the diagnosis changes or after each material remediation
attempt. Keep notes redacted and useful for a human skimming the incident.

## Support Engagement

Use legacy OpenDeploy support engagement only when an alarm exists. If the
agent cannot resolve an alarm ID, do not search forever and do not fabricate an
alarm. Use `opendeploy-oncall` instead:

```bash
opendeploy oncall status --json
# if no channel exists:
opendeploy oncall setup --json
```

Return `discord_url` or `authorize_url` to the user as the private OpenDeploy
support channel. If the agent wrote `.opendeploy/support-evidence.md`, mention
that the user can paste or attach that redacted packet in Discord.

Use legacy alarm-backed OpenDeploy support engagement when:

- the user explicitly asks to engage/page/contact OpenDeploy support;
- the alarm is critical/high and platform evidence points to OpenDeploy infra;
- logs or required observability are unavailable because of an OpenDeploy auth,
  gateway, monitoring, builder, or runtime issue;
- the agent has made one concrete safe remediation and the alarm is still
  active.

Ask with `AskUserQuestion` before engaging support unless the user already gave
that exact approval in the current request. The question should include:

- alarm ID and severity;
- affected project/service IDs;
- the redacted evidence packet that will be sent;
- whether support engagement may notify OpenDeploy oncall.

After approval, post the evidence packet as a note, then engage support:

```bash
opendeploy monitoring alarms note <ALARM_ID> \
  --note-type action_item \
  --text "Support request: <timeline>; evidence: <logs/status redacted>; ask: <specific help needed>." \
  --json

opendeploy monitoring alarms engage-support <ALARM_ID> \
  --by opendeploy-agent \
  --message "Support request: <timeline>; evidence: <logs/status redacted>; ask: <specific help needed>." \
  --json
```

Backend behavior: support engagement marks `support_engaged=true` on the alarm
and sends the server-side OpenDeploy support webhook when configured. The
`--message` text is included in the oncall webhook as the agent update. Do not
send support webhooks manually from the skill.

`support-checkin` is for OpenDeploy staff/admin credentials only. If a normal
user or guest token receives 403, report that support has not checked in yet;
do not retry or spoof staff identity.

For alarm investigation conversations in Discord, use `opendeploy-oncall`
instead. When the user says "look into this alarm and tell the team", use both:
acknowledge or note the alarm here, then post investigation updates through
`opendeploy-oncall`.

## Lifecycle Actions

All lifecycle actions require explicit user consent unless the user directly
asked for that exact action.

```bash
# Take ownership of investigation; post a note first.
opendeploy monitoring alarms acknowledge <ALARM_ID> --by opendeploy-agent --json

# Temporarily hide noise; always include duration in the user question.
opendeploy monitoring alarms suppress <ALARM_ID> --duration 30m --json

# Resolve only after recovery is verified and a resolution note is posted.
opendeploy monitoring alarms resolve <ALARM_ID> \
  --resolution "Verified healthy after <fix>; URL/status checked at <time>." \
  --by opendeploy-agent \
  --json
```

Rules:

- `acknowledge` means the agent is actively investigating; it is not a fix.
- `suppress`/`silence` hides future alerts for a duration; never suppress
  without duration and reason.
- `resolve` requires read-back verification that the alarm condition recovered.
- `delete` is not allowed from skills. Use a dashboard handoff.
- Alert-rule create/update/delete is configuration work; use explicit consent
  and prefer `opendeploy-ops`/dashboard until the user asks for rule changes.

## Final Response

Return:

- current alarm state and severity;
- actions the agent took;
- whether OpenDeploy support was engaged or checked in;
- latest service/dependency health;
- remaining user or OpenDeploy oncall action items.
