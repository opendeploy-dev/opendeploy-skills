# Auth Reference - CLI Only

OpenDeploy auth for agents is CLI-owned. Do not hand-write credential creation
requests in Markdown or shell snippets.

## Commands

Check auth and binding state:

```bash
opendeploy auth status --json
```

CLI `0.1.19+` uses the saved `guest_id` + `bind_sig` to check whether a local
`od_a*` deploy credential has already been linked to a dashboard account. Trust
`binding_state` from this command; do not infer bound/unbound from the auth file
shape.

Create a local deploy credential only after explicit user consent:

```bash
opendeploy auth guest --name "$AGENT_DISPLAY_NAME" --json
```

Choose `AGENT_DISPLAY_NAME` yourself. Use a short human-friendly label that
helps the user recognize this agent on the bind page, such as `Codex on
Workstation`. The name is display-only, can be changed by the user later, and
must never be treated as an auth matching key.

Inspect local deploy credential binding state:

```bash
opendeploy auth guest-status --json
```

For dashboard/API-key auth:

```bash
opendeploy auth login --json
opendeploy auth api-key show --json
```

## Consent Rule

If no `OPENDEPLOY_TOKEN`, profile key, or `~/.opendeploy/auth.json` key exists,
the agent must use the host's structured question UI before `auth guest`.
Do not ask the user to type magic phrases. Do not create local deploy credentials in
CI/headless/non-interactive contexts; require a pre-provisioned token there.

The consent prompt must say:

- First deploy is free, requires no OpenDeploy account creation, and asks for
  no payment method.
- OpenDeploy will create one local deploy credential so the agent can deploy
  without making the user sign up first.
- The credential is written to `~/.opendeploy/auth.json` with mode `0600`.
- The token is sent only to `https://dashboard.opendeploy.dev/api`.
- The first successful deploy returns a live `*.opendeploy.site` URL and then an
  optional account-binding URL.
- Removing skill files does not revoke the saved token.

## Auth File Shape

`~/.opendeploy/auth.json`:

```json
{
  "version": 1,
  "api_key": "od_axxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "gateway": "https://dashboard.opendeploy.dev/api",
  "guest_id": "8f3e2b14-ad7c-4f0c-9b1d-aaaaaaaaaaaa",
  "bind_sig": "0123456789abcdef"
}
```

Treat every `od_*` token and `bind_sig` as secret. Never print them standalone.
Only show the full account-binding URL after a deployment is active, preferably
from:

```bash
opendeploy deploy report "$DEPLOYMENT_ID" --json
```

## Readiness Checks

After creating a fresh local deploy credential, use a route that unbound local
deploy credentials can read:

```bash
opendeploy regions list --json
```

Do not use `opendeploy auth whoami` as the local credential readiness check; profile reads
may be account-only for unbound credentials.

If project/deployment/log reads return 401 or 403 after successful writes, stop
and ask the user to bind the credential or provide an `od_k*` dashboard token.
Do not blindly retry deploys without logs.
