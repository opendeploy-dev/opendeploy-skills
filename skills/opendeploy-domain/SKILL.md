---
name: opendeploy-domain
version: "0.0.20"
description: Manage OpenDeploy auto subdomains, custom domains, DNS checks, CNAME setup, and domain verification. Use when the user says domain, custom domain, hostname, custom hostname, subdomain, rename subdomain, URL, DNS, CNAME, SSL, TLS, primary domain, verify domain, bind domain, check DNS, or make a custom hostname live.
user-invokable: true
---

# OpenDeploy Domain

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

Auto subdomain rename is allowed after deploy. Custom domains require an
account-bound credential, DNS ownership, and explicit consent.

```bash
opendeploy domains list --service <service-id> --json
opendeploy domains check-subdomain <prefix> --json
opendeploy domains update-subdomain <domain-id> --subdomain <prefix> --json
```

Auto subdomain rename means updating the single existing `*.opendeploy.site`
auto-domain row for the service. A service must have only one auto domain.
Legacy services may still show `*.opendeploy.run` rows; treat those as
OpenDeploy-owned auto domains too. Do not call `opendeploy domains create` for
`*.opendeploy.site`, `*.dev.opendeploy.site`, legacy `*.opendeploy.run`, or
`type=auto`; that creates a second domain row and can leave a failed stale
entry. If the service has no auto-domain row, treat that as a platform state
issue and run `opendeploy deploy report <deployment-id> --json` / `domains list`
again rather than creating a new auto row.

Rename flow:

1. `opendeploy domains list --service <service-id> --type auto --json`
2. Choose the one non-failed auto row for the service. If several auto rows are
   returned, prefer `active`, then `verified`, then `pending`; report failed
   rows as stale platform state but do not ask the user to delete them for a
   normal rename.
3. `opendeploy domains check-subdomain <prefix> --json`
4. If available, run `opendeploy domains update-subdomain <domain-id> --subdomain <prefix> --json`.
5. Read back `domains get` and `domains list`; final state should show exactly
   one active/verified/pending auto domain for the service.

If `check-subdomain` says unavailable because a failed OpenDeploy auto-domain row
already uses the requested prefix, do not tell the user to manually delete it
as the first answer. Retry `update-subdomain` against the current non-failed
auto row. Newer backends clean stale failed OpenDeploy-managed rows for the
same service, even if an older binary accidentally created them as
`type=custom`. If the backend still returns conflict, explain that stale failed
domain cleanup is needed on the platform side and provide the
project/service/domain IDs; do not create another row.

Custom domain flow:

```bash
opendeploy auth status --json
opendeploy auth guest-status --json
opendeploy domains list --service <service-id> --json
opendeploy domains create --service <service-id> --domain app.example.com --type custom --confirm-custom-domain --json
opendeploy dns check app.example.com --json
```

## Custom domain workflow

Do not start by calling `domains create`. Teach the user the DNS work first,
then ask for confirmation. The user often does not know that a dashboard/agent
domain action still requires a DNS change at their registrar.

For provider-specific DNS steps, Cloudflare proxy handling, and failed
verification interpretation, load `../opendeploy/references/domain.md`. Load it
whenever the user asks "how do I add this?", says they are done but DNS check
fails, or the check resolves to CDN/proxy IPs instead of OpenDeploy.

Before custom domain mutation:

- user owns the hostname
- user can edit DNS
- credential is account-bound
- DNS change and SSL issuance may take minutes

Explain the DNS plan in plain language:

- The current `*.opendeploy.site` URL keeps working while DNS/SSL is being set up.
- The custom hostname must be a subdomain such as `app.example.com`.
- If the user asks for an apex/root domain such as `example.com`, warn that many
  DNS providers do not allow CNAME at the root; ask whether they want `www` /
  another subdomain, or whether their DNS provider supports ALIAS/ANAME.
- For a hostname such as `app.example.com`, most DNS providers want:
  - Type: `CNAME`
  - Name/Host: `app` (or the full `app.example.com` if the provider asks)
  - Target/Value: the `cname_target` returned by OpenDeploy after create
  - TTL: Auto or 300 seconds
- If the DNS provider has a proxy toggle such as Cloudflare's orange cloud, use
  DNS-only until OpenDeploy verification and SSL are active.
- Remove conflicting A/AAAA/CNAME records for the same hostname before checking.
- If the provider is unknown, still give exact generic steps plus the common
  Cloudflare path. If DNS check returns Cloudflare anycast IPs, infer the record
  is proxied and tell the user how to switch that one record to DNS-only.

Use a structured `AskUserQuestion` / approval UI when available. Put
`(Recommended)` in the recommended option label itself:

1. "I can edit DNS; create domain (Recommended)" - user confirms ownership and
   consents to custom-domain binding.
2. "Show me DNS steps first" - explain the host/name/target flow and stop before
   mutation.
3. "Cancel" - no mutation.

Only after the user confirms option 1, run:

```bash
opendeploy domains create \
  --service "$SERVICE_ID" \
  --domain "$CUSTOM_DOMAIN" \
  --type custom \
  --confirm-custom-domain \
  --json
```

Read `cname_target` from the create response. Never hardcode it. Surface the
exact DNS record to the user and pause until they say it has been added. Include
both the short host label and the full hostname so non-technical users can map
it to their provider's UI.

Then verify:

```bash
opendeploy dns check "$CUSTOM_DOMAIN" --json
opendeploy domains get "$DOMAIN_ID" --json
opendeploy domains list --service "$SERVICE_ID" --json
```

If DNS has not propagated, explain what is missing and ask the user to update
DNS. Do not retry random consent forms such as `--query consent=true`,
`--data '{"consent":true}'`, or custom headers. The only CLI consent flag for
this flow is `--confirm-custom-domain`.

If `dns check` shows Cloudflare anycast IPs (`104.*`, `172.64.*`-`172.71.*`,
`188.114.*`) or says the domain did not resolve to OpenDeploy, tell the user to
edit the CNAME row and change Proxy status from proxied/orange cloud to
DNS-only/gray cloud, then re-run `opendeploy dns check "$CUSTOM_DOMAIN" --json`
and `opendeploy domains get "$DOMAIN_ID" --json`. Do not create another domain
row.

If the credential is not account-bound, stop before create. Surface the
account-binding link from `opendeploy deploy report <deployment-id> --json` if
available, or ask the user to sign in and provide an account-bound/dashboard
token. Do not keep trying custom-domain create with an unbound local deploy
credential.

Do not delete domain rows from the skill; use dashboard handoff for deletes.
