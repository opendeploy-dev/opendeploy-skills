# OpenDeploy Oncall CLI Reference

This reference mirrors the current backend and CLI implementation for the
OpenDeploy private Discord support-channel feature. Use it when the main skill
needs exact commands, API routes, or response shapes.

## Feature Summary

OpenDeploy oncall v1 creates a permanent private Discord channel for the
authenticated OpenDeploy user. The channel is primarily the direct support room
users can open whenever a deploy fails or they need help from OpenDeploy staff.
This is not agent auto-oncall yet. For each real alarm, OpenDeploy can also
create or reuse a Discord thread inside that channel. System bot messages post
alarm lifecycle events, and the agent can post concise investigation updates
with `opendeploy oncall post` when an alarm ID exists.

The dashboard setup popup can hand a prompt to the agent. Setup still happens
inside the agent session: the dashboard shows status and links, but the agent
owns asking the user to open the OAuth URL and confirming setup.

## Commands

Use the CLI's default production gateway. Add `--base-url` only for explicit
non-production gateway testing.

| Command | Backend route | Use |
|---|---|---|
| `opendeploy oncall setup --json` | `POST /v1/oncall/channels/me` | Issue Discord OAuth URL and begin setup. |
| `opendeploy oncall status --json` | `GET /v1/oncall/channels/me` | Read current channel state. |
| `opendeploy oncall post --alarm <id> --message "..." --json` | `POST /v1/alarms/:id/oncall-post` | Post to a specific alarm thread. |
| `opendeploy oncall post --message "..." --json` | `POST /v1/alarms/active/oncall-post` | Post to the most recent active alarm. |
| `opendeploy oncall pause --json` | `POST /v1/oncall/channels/me/pause` | Stop future posts while keeping channel/thread history. |
| `opendeploy oncall resume --json` | `POST /v1/oncall/channels/me/resume` | Resume posting. |
| `opendeploy oncall delete --confirm --json` | `DELETE /v1/oncall/channels/me?confirm=true` | Destructive teardown of the channel and thread rows. |

Do not use `opendeploy oncall post "message"`; the CLI requires
`--message "message"`.

For support cases without an alarm ID, do not use `opendeploy oncall post`
yet. The current backend has no general channel-post route; it only posts into
alarm threads. Use:

```bash
opendeploy oncall status --json
# if 404:
opendeploy oncall setup --json
```

Then return `discord_url` from status or `authorize_url` from setup to the user
as the private OpenDeploy support channel entrypoint. Render it as a clickable
Markdown link, not a code block:

```markdown
[Open Discord authorization link](<AUTHORIZE_URL>)
[Open private OpenDeploy Discord channel](<DISCORD_URL>)
```

Use the returned URL exactly as the link target. If the agent prepared a support
packet, tell the user to paste or attach the redacted packet in that channel.

## Setup Responses

`opendeploy oncall setup --json`:

```json
{
  "authorize_url": "https://discord.com/oauth2/authorize?client_id=...&state=...",
  "status": "pending_oauth"
}
```

The agent must provide `authorize_url` as a clickable Markdown link. Do not put
it in fenced code, indented code, or inline backticks. The channel is not created
when setup is called; it is created after Discord redirects to
`/api/v1/oncall/oauth/discord/callback`.

`opendeploy oncall status --json` after setup:

```json
{
  "id": "channel-row-id",
  "discord_channel_id": "1234567890",
  "discord_channel_name": "oncall-a1b2c3d4",
  "discord_url": "https://discord.com/channels/<guild>/<channel>",
  "agent_type": "user_agent",
  "paused": false,
  "created_at": "2026-05-03T12:00:00Z"
}
```

If setup has not completed, status returns a 404 error saying no channel exists.

## Posting Responses

Specific alarm:

```json
{
  "posted": true,
  "alarm_id": "alarm-uuid"
}
```

Most recent active alarm, with more than one candidate:

```json
{
  "posted": true,
  "alarm_id": "newest-active-alarm-uuid",
  "disambiguation": [
    {
      "id": "newest-active-alarm-uuid",
      "title": "CPU 95% on api-server",
      "severity": "critical",
      "first_occurred_at": "2026-05-03T12:00:00Z"
    },
    {
      "id": "other-active-alarm-uuid",
      "title": "Memory 80% on worker",
      "severity": "high",
      "first_occurred_at": "2026-05-03T11:55:00Z"
    }
  ]
}
```

`posted: false` is a no-op success. It can mean the alarm is currently
suppressed, the oncall channel is paused, or a duplicate `dedupe_key` was
accepted without reposting. The CLI does not expose `agent_label` or
`dedupe_key` flags yet, so normal agent usage should treat `posted: false` as
"inspect status; do not retry blindly."

## Backend Behavior

- Setup validates Discord config; if missing, backend returns 503.
- OAuth state is signed, expires, and has replay protection.
- The channel slug is opaque (`oncall-<8hex>`), one channel per user.
- Webhook tokens are encrypted at rest.
- A thread is unique per alarm and is created lazily on first lifecycle or
  agent post.
- System bot lifecycle events currently include alarm fired, severity
  escalated, and alarm resolved.
- Muted/suppressed alarms are silent for both system bot and agent posts.
- Paused channels keep Discord resources but drop posts until resumed.
- Delete hard-deletes the DB channel/thread rows and best-effort deletes the
  Discord channel; reconciliation handles Discord leftovers.

## Exact Cadence

Initial post, within about one minute of investigation start:

```bash
opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Investigating: <one-line hypothesis>." \
  --json
```

Diagnosis update:

```bash
opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Confirmed: <cause>. Next: <safe action>." \
  --json
```

Action update:

```bash
opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Action: <rollback/restart/config change> started. ETA <time>." \
  --json
```

Resolution update:

```bash
opendeploy oncall post --alarm "$ALARM_ID" \
  --message "Resolved: <verification>. Follow-up: <short next item>." \
  --json
```

Keep messages short, redacted, and useful for OpenDeploy staff joining the
thread cold.
