# Domain Reference - CLI Only

Use this reference for OpenDeploy auto subdomains, custom domains, DNS checks,
and domain retry. Default execution is through `@opendeploydev/cli`; do not use
raw gateway calls for normal domain work.

## Auto Subdomain

Check availability:

```bash
opendeploy domains check-subdomain "$SUBDOMAIN" --json
```

Find the current auto-domain row:

```bash
opendeploy domains list --service "$SERVICE_ID" --type auto --json
```

Rename:

```bash
opendeploy domains update-subdomain "$DOMAIN_ID" --subdomain "$SUBDOMAIN" --json
```

This is an update, not a create. A service can have only one OpenDeploy auto
domain (`*.opendeploy.site` / `*.dev.opendeploy.site`; legacy projects may
still show `*.opendeploy.run`). Never use
`opendeploy domains create` with `type=auto`, an `opendeploy.site` hostname, or
a legacy `opendeploy.run` hostname to
rename an auto subdomain; doing so creates a second row and may leave a failed
stale domain. If `domains list --service "$SERVICE_ID" --type auto` returns
several rows, choose the current non-failed row (`active` > `verified` >
`pending`) as the update target and report failed rows as stale platform state.
Do not ask the user to delete failed OpenDeploy auto-domain rows before trying the
proper `update-subdomain` path. Newer backends can clean a stale failed
OpenDeploy-managed row for the same service even when an older binary
accidentally created it as `type=custom`.

On conflict, append a short suffix once, then re-check availability. Auto
subdomain rename is allowed for unbound local deploy credentials because it
does not change billing or custom DNS ownership.

## Custom Domain

Custom domains require an account-bound credential. If the current token is an
unbound local deploy credential, stop and surface the account-binding URL from:

```bash
opendeploy deploy report "$DEPLOYMENT_ID" --json
```

Before mutation, teach the DNS work and ask for confirmation. The user must
understand that OpenDeploy can create the custom-domain row, but they still
must add/update DNS at their provider. The existing `*.opendeploy.site` URL keeps
working while DNS and SSL are being set up.

Pre-bind checklist:

1. Verify the current auth is account-bound (`auth status` / `auth guest-status`).
2. Verify the service already has a working OpenDeploy URL.
3. Explain the DNS record shape before create:
   - subdomain hostnames use CNAME
   - apex/root domains may need ALIAS/ANAME or a `www` subdomain
   - Cloudflare/proxy providers should stay DNS-only until verification is active
   - conflicting A/AAAA/CNAME records for the same hostname must be removed
4. Ask the user to confirm ownership, DNS access, custom-domain consent, and
   awareness that propagation/SSL can take minutes.

If the user asks "how do I add it?", give actionable steps immediately. Do not
ask which DNS provider first and leave them blocked; give the generic steps plus
the Cloudflare path, then ask for the provider or screenshot if they need exact
clicks.

Create:

```bash
opendeploy domains create \
  --service "$SERVICE_ID" \
  --domain "$CUSTOM_DOMAIN" \
  --type custom \
  --confirm-custom-domain \
  --json
```

Read `cname_target` from the create response. Never hardcode it. Then show the
user the exact DNS row to add:

```text
Type:  CNAME
Name:  <leftmost label for this zone, e.g. app for app.example.com>
Value: <cname_target from OpenDeploy>
TTL:   Auto or 300
Proxy: DNS-only until OpenDeploy says active
```

Also show the provider guidance below, using the user's actual domain labels.
For `app.example.com`, `<host>` is `app`, `<full-hostname>` is
`app.example.com`, and `<target>` is the `cname_target`.

### DNS setup guidance

Use this shape in user-facing guidance:

```text
You need to add one DNS record where example.com is managed:

Type:   CNAME
Name:   app
Target: <target from OpenDeploy>
TTL:    Auto or 300 seconds
Proxy:  DNS-only until OpenDeploy shows SSL active

If your DNS UI asks for the full hostname instead of "Name", enter:
app.example.com
```

Then give the common click paths:

- **Cloudflare**: Websites -> the user's zone -> DNS -> Records -> Add record.
  Choose `CNAME`, set Name to `<host>`, Target to `<target>`, Proxy status to
  **DNS only** (gray cloud), TTL Auto, then Save. If a `<host>` row already
  exists, edit that row instead. Delete any `A` / `AAAA` row for `<host>`.
- **Namecheap**: Domain List -> Manage -> Advanced DNS -> Host Records -> Add
  New Record -> `CNAME Record`. Host `<host>`, Value `<target>`, TTL
  Automatic. Remove conflicting `A` / `AAAA` records for the same host.
- **GoDaddy**: My Products -> domain -> DNS -> Add New Record. Type `CNAME`,
  Name `<host>`, Value `<target>`, TTL Default/600. Save.
- **Route 53**: Hosted zones -> the user's zone -> Create record. Record name
  `<host>`, type `CNAME`, value `<target>`, routing Simple, TTL 300.
- **Vercel/Netlify DNS**: Domain DNS settings -> Add record -> `CNAME`, Name
  `<host>`, Value `<target>`. Do not add another platform's proxy in front
  until OpenDeploy verification is active.

Explain the conflict rule plainly: a hostname cannot have CNAME and A/AAAA
records at the same time. If the UI says the record already exists, edit the
existing `<host>` row or remove the conflicting A/AAAA row first.

Pause until the user confirms the DNS row has been added. Then check DNS:

```bash
opendeploy dns check "$CUSTOM_DOMAIN" --json
```

Retry after DNS changes:

```bash
opendeploy domains retry "$DOMAIN_ID" --json
```

If the gateway returns `consent_required`, do not guess with query params,
inline JSON consent, or custom headers. Ask the user, then retry only with
`--confirm-custom-domain`. If it still returns `consent_required`, stop and
report the contract mismatch with the project/service/domain ids.

## DNS Check Results

Interpret `opendeploy dns check "$CUSTOM_DOMAIN" --json` for the user in plain
language:

- `cname_target` matches OpenDeploy and domain status is `active`/`verified`:
  tell the user the DNS side is done, then wait for or verify SSL.
- `NXDOMAIN`, empty answer, or "no record": the DNS row is not saved in the
  authoritative zone yet, or the user edited the wrong DNS provider. Ask them
  where the domain is managed and to confirm the CNAME exists there.
- CNAME exists but points somewhere else: tell the user to edit the existing
  row's target to OpenDeploy's target. Do not create a second row.
- Resolved IPs are Cloudflare anycast (`104.*`, `172.64.*`-`172.71.*`,
  `188.114.*`), or the check says DNS did not resolve to OpenDeploy: the row is
  likely proxied. Tell the user:

```text
In Cloudflare, open DNS -> Records, find the CNAME row for <host>, and click
the orange cloud so it becomes gray and says "DNS only". Save, wait 30-120
seconds, then I will check again. Keep it DNS-only until OpenDeploy says SSL is
active.
```

- CNAME is correct but status is still pending: this can be DNS cache or SSL
  issuance delay. Recheck every 30-60 seconds for a few minutes. Do not create
  another domain row.
- SSL failed with "did not return our challenge file" or 404: DNS is probably
  hitting another CDN/app instead of OpenDeploy. Check for proxy/CDN mode,
  conflicting records, or an old host target.

If the user is non-technical, avoid terse phrases like "ACME failed". Say:
"OpenDeploy needs to fetch a verification file from your domain. Right now the
request is going somewhere else, so SSL cannot finish yet."

## Verification

After any domain mutation:

```bash
opendeploy domains get "$DOMAIN_ID" --json
opendeploy domains list --service "$SERVICE_ID" --json
opendeploy deploy report "$DEPLOYMENT_ID" --json
```

Only tell the user a domain is live after the CLI or an HTTP check confirms it.
Do not expose `bind_sig`, bearer tokens, SSL private keys, or DNS-provider
credentials.
