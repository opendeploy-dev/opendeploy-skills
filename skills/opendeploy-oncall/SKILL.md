---
name: opendeploy-oncall
version: "0.0.20"
description: Get help from OpenDeploy staff through the user's private Discord support channel when a deploy fails, OpenDeploy has a platform/upload/CLI issue, or the user asks to contact OpenDeploy support. This is not agent auto-oncall; the agent keeps investigating locally while this skill returns or sets up the support link.
user-invokable: true
---

# OpenDeploy Oncall

Use this skill to get help from OpenDeploy staff through the user's private
Discord support channel whenever a deploy fails or the user has an OpenDeploy
issue. This is not agent auto-oncall yet: the agent keeps investigating in the
local session, and this skill returns or sets up the private Discord link so the
user can reach us. When a real alarm ID exists, the skill can also post concise
updates to that alarm's Discord thread. The user stays in control of setup,
pause/resume, and teardown.

Do not use raw `curl`. Use the global `opendeploy` CLI that passed the OpenDeploy
version gate. If another OpenDeploy skill already ran the global CLI version
check and `opendeploy preflight . --json` in this session, do not repeat it.
Oncall uses the CLI's default production gateway
(`https://dashboard.opendeploy.dev/api`). Keep commands clean. Only add
`--base-url` when the user explicitly asks to test a non-production gateway.

## When To Invoke

Decision tree:

```text
Did the user ask for help from OpenDeploy, private Discord support, or a way to
contact us after a failed/stuck deploy/upload/platform operation?
|- Yes -> continue to support channel setup/link
`- No  -> did the user see or mention an alarm and explicitly ask to keep
         OpenDeploy in the loop?
         |- Yes -> continue to alarm conversation
         `- No  -> not this skill

Does the user want Discord/OpenDeploy team conversation?
|- No  -> use opendeploy-alarms/opendeploy-debug for lifecycle or debugging only
`- Yes -> continue

Has oncall already been set up?
|- Yes -> if alarm exists, go to "Posting"; if no alarm, return `discord_url`
`- No  -> go to "Setup"
```

Check setup first:

```bash
opendeploy oncall status --json
```

A 200 response means setup exists. A 404 response saying no oncall channel
exists means run setup. Do not re-run setup when status already returns a
channel. If the dashboard prompt or setup config says oncall is disabled, stop
and tell the user this OpenDeploy instance has oncall disabled.

When there is no alarm ID, `status` or `setup` is the whole support engagement
flow for now:

- If `status` returns `discord_url`, surface that private Discord channel URL
  to the user as a clickable Markdown link and tell them to open it to reach
  OpenDeploy support.
- If `status` returns 404, run setup and surface the returned `authorize_url`.
- Do not call `opendeploy oncall post --message ...` without an alarm for
  CLI-side upload failures or other non-alarm support cases. The current
  backend posts only into alarm threads; setup/status provides the private
  support channel.

URL rendering rule: Discord URLs must be clickable links, not code. Do not wrap
`authorize_url` or `discord_url` in a fenced code block, indented code block, or
inline backticks. Use the returned URL exactly as the Markdown target:

```markdown
[Open Discord authorization link](<AUTHORIZE_URL>)
[Open private OpenDeploy Discord channel](<DISCORD_URL>)
```

## Setup

Run setup only once per user:

```bash
opendeploy oncall setup --json
```

The CLI returns `authorize_url`. If you run without `--json`, it prints:

```text
Open this URL in your browser to join the OpenDeploy oncall Discord channel:

    https://discord.com/oauth2/authorize?client_id=...&state=...

After you authorize, your private oncall channel will be created automatically.
```

Surface the URL to the user verbatim. Do not truncate it, paraphrase it, or
open it yourself. "Verbatim" means the Markdown link target must be the exact
returned URL; it does not mean printing the URL in code format.

If this flow was triggered by "engage OpenDeploy support" without an alarm,
also tell the user that this link joins their private OpenDeploy support
channel. If the agent wrote a support packet such as
`.opendeploy/support-evidence.md`, tell the user they can attach or paste the
redacted packet there. Then pause:

```text
Open the URL above in your browser, click Authorize on Discord, and tell me
when you see the success page.
```

After the user confirms, verify:

```bash
opendeploy oncall status --json
```

If status still returns 404, setup did not complete. Likely causes are an
expired OAuth state token, the user clicked Cancel, or the backend OAuth
callback is misconfigured. Ask the user to retry:

```bash
opendeploy oncall setup --json
```

## Posting

Post one update per meaningful state change. Always pass `--alarm <id>` when
you know the alarm ID:

```bash
opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Investigating: CPU spike began after deploy abc123; checking runtime logs." \
  --json

opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Confirmed: /api/feed is issuing N+1 queries; rollback initiated, ETA 2 min." \
  --json

opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Resolved: rollback complete, CPU back to 23%, health checks green." \
  --json
```

Use the zero-alarm form only when you genuinely do not have an alarm ID:

```bash
opendeploy oncall post --message "Investigating the newest active alarm." --json
```

Rules:

- Keep each Discord post under about 500 characters.
- Do not post every command or every log line; post hypothesis, confirmation,
  action, and resolution.
- Never paste secrets, tokens, bearer headers, bind signatures, private env
  values, full env dumps, or unredacted customer data into Discord.
- Do not post to resolved or muted alarms. If the backend returns
  `{ "posted": false }`, do not retry blindly; inspect alarm mute/resolution
  state and `opendeploy oncall status --json`.
- Pair conversation with lifecycle when appropriate: use `opendeploy-alarms`
  to acknowledge/resolve/suppress, and this skill to talk in Discord.

## Disambiguation

If you omit `--alarm` and there are multiple active alarms, the backend posts
to the most recent active alarm and may return a disambiguation list:

```json
{
  "posted": true,
  "alarm_id": "abc-123",
  "disambiguation": [
    {"id": "abc-123", "title": "CPU 95% on api-server", "severity": "critical"},
    {"id": "def-456", "title": "Memory 80% on worker", "severity": "high"}
  ]
}
```

Confirm with the user which alarm the post belonged to. If it was wrong,
re-issue the update with `--alarm <correct-id>` and explain the correction.

## Pause And Resume

If the user says to stop posting to Discord:

```bash
opendeploy oncall pause --json
```

Resume later:

```bash
opendeploy oncall resume --json
```

The Discord channel and alarm threads remain. Posting is just gated while
paused.

## Tear Down

Only do this when the user explicitly asks to delete the oncall channel or
start over:

```bash
opendeploy oncall delete --confirm --json
```

Ask the user first with `AskUserQuestion`. This deletes the Discord channel and
all thread history for that oncall channel. The CLI and backend both refuse the
delete without explicit confirmation; never auto-pass `--confirm`.

## Not Supported In v1

- `opendeploy oncall watch` is not available. The CLI v1 is post-only; inbound
  Discord message subscription is a future feature.
- Switching agent type is not available from the CLI. Delete + setup is the
  current reset path.
- Per-project oncall opt-out is not available. v1 is per user across projects.

## Failure Handling

| Output | Cause | Agent action |
|---|---|---|
| 404 `no oncall channel exists for this user` from `status` | Setup has not completed | Run the setup flow. |
| 404 `no active alarms - pass --alarm <id>` | Zero-alarm post with no active alarm | Ask which alarm to post to, then retry with `--alarm`. |
| 400 `confirmation required` | Delete called without confirmation | Do not auto-add `--confirm`; ask first. |
| 412 `user has not set up oncall yet` | Posting before setup | Run setup, then retry the post once. |
| 503 `Discord integration is not configured` | Backend missing Discord configuration | Tell the user and do not retry. |
| `{ "posted": false }` | Alarm is muted/suppressed, channel is paused, or the post was deduplicated | Do not retry blindly. Check alarm state and oncall status. |

For exact command shapes and response contracts, load
`references/oncall-cli.md`.
