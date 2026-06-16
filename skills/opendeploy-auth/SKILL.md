---
name: opendeploy-auth
version: "0.0.20"
description: Manage OpenDeploy authentication. Use when the user says login, log in, sign in, auth, auth status, whoami, token, OpenDeploy token, dashboard token, local deploy credential, guest credential, anonymous credential, bind account, account binding link, credential rejected, 401, or asks to inspect credential binding state.
user-invokable: true
---

# OpenDeploy Auth

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

Auth is explicit. Never create a local deploy credential without user approval.

```bash
opendeploy auth status --json
```

If no credential exists, ask before:

```bash
opendeploy auth guest --name "$AGENT_DISPLAY_NAME" --json
```

Choose `AGENT_DISPLAY_NAME` yourself before calling the command, such as
`Codex on Workstation` or `Claude Code on Laptop`. It is display-only for the
account-binding page and user settings; it must not be used to match or verify
auth.

Dashboard-token path:

```json
{"version":1,"api_key":"od_k...","gateway":"https://dashboard.opendeploy.dev/api"}
```

Write to `~/.opendeploy/auth.json` with mode `0600`.

Binding:

- the skill never calls dashboard OIDC bind endpoints
- derive and print the account-binding URL only after an active deploy URL
  exists, except when a bind-required API is the only forward path
- never print `bind_sig` standalone

For 401 recovery, do not silently delete or replace credentials. Ask whether
the user wants to paste a fresh token, open the dashboard, delete and start
fresh, or cancel.

## Register risk control (429)

`opendeploy auth guest` runs through a challenge-PoW-register pipeline. When
the same source IP issues many register attempts in a short window, the
gateway risk engine refuses to mint another challenge — instead of silently
escalating proof-of-work to a level the CLI would grind on for minutes.

Detection — the response is HTTP 429 with shape:

```json
{
  "error": "rate_limited",
  "reason": "ip_over_quota_retry",
  "retry_after_seconds": 3600,
  "message": "Too many register attempts from this IP. Wait before retrying — repeated retries will keep the cooldown alive."
}
```

What to do:

- Do NOT auto-retry. Each retry inside the window keeps the cooldown alive
  and prolongs the block.
- Surface `retry_after_seconds` and `message` to the user verbatim.
- Tell the user this is the gateway's register risk control, not a token
  problem — `auth.json` is not stale, the CLI is not broken; the IP is in
  cooldown.
- Suggested user options:
  1. Wait the indicated `retry_after_seconds` and try again once.
  2. Switch network (different Wi-Fi / hotspot / VPN egress) so the next
     attempt comes from a cold IP.
  3. If the user has a dashboard account, sign in there and create a
     personal API key instead of guest registration.

If the user has been hitting `auth guest` repeatedly because the previous
call appeared to hang, that earlier hang was the high-PoW path the gateway
no longer issues — the fix is to wait, not to retry harder.

## Rotate (bound local deploy credential)

Use only when the user says rotate, leaked, compromised, regenerate token,
new api key, or you suspect the existing token has been exposed (committed
to git, posted in chat, etc.). Only account-bound local deploy credentials can self-rotate;
pending agents must be bound first, dashboard tokens (`od_k*`) rotate from
the dashboard.

```bash
opendeploy auth guest rotate --json
```

Server invalidates the old token immediately and returns a new `api_key`.
The CLI overwrites `~/.opendeploy/auth.json` with the new value. If the
write fails, the response includes `auth_file_written: false` and the new
`api_key` — relay that to the user verbatim and instruct them to save it
into `~/.opendeploy/auth.json` before any further command. Do not retry
the rotate; the new key is already live, only the local copy is missing.

Rate limit: 3 rotations per agent per 24h. On 429, surface `Retry-After`
to the user; do not auto-retry.

Never cache the returned `api_key` in skill output, transcripts, or logs.
Surface it once in the JSON response and move on.
