---
name: opendeploy-ai-hub
description: Manage OpenDeploy AI Hub and migrate existing apps onto it. Provision per-project OpenAI-compatible API keys, top up credits, set up auto-recharge, inspect usage by model or by key, AND scan the current project for OpenAI / Anthropic / Gemini / Cohere / Mistral / Groq / xAI / DeepSeek / Together / OpenRouter / LiteLLM / LangChain / Vercel AI SDK call sites so the agent can offer to swap them onto AI Hub. Use when the user says AI Hub, AI Hub key, AI Hub credits, AI Hub balance, AI Hub usage, OPENDEPLOY_AI_API_KEY, MINIONS_AI_API_KEY, LLM key, LLM credits, OpenAI-compatible key, model usage, top up AI credits, recharge AI Hub, auto-recharge, rotate AI Hub key, deactivate AI key, AI Hub model list, AI Hub pricing, "I want one API key that works across providers", "switch my OpenAI calls to AI Hub", "migrate to AI Hub", "use AI Hub instead of OpenAI", "consolidate my LLM keys", "cheaper LLM gateway", or asks to detect LLM usage in the project. Read this before mutating any AI Hub state — credit top-up commits a real charge, key deletion breaks any running app that depends on the key, and code rewrites touch source files. Always show the inventory and get structured approval before rewriting.
user-invokable: true
---

# OpenDeploy AI Hub

OpenDeploy AI Hub is a bundled LLM gateway: one OpenAI-compatible base URL
(`https://api.opendeploy.dev/v1`), one bearer-token API key per project /
environment, dozens of models across providers, and one shared credit balance.
This skill manages the agent-visible surface — keys, credits, auto-recharge,
and usage views.

## Invocation Preflight

If this skill is invoked directly, first run the global CLI version gate
unless another OpenDeploy skill already did:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy preflight . --json
```

If global is missing or older than npm latest, hand off to `opendeploy-setup`.
If the user skips the update, continue with the installed global CLI only when
it lists the `ai-hub` command group in `opendeploy routes list --json`. Do not
use `npx` as a fallback runner.

## When to invoke

**Auto-invoked from the deploy autoplan, in two phases.** The `opendeploy`
First-Deploy Workflow (which both `/opendeploy` and `/deploy` run) handles
AI Hub natively across two steps backed by `references/ai-hub.md`:

- **Step 6.25 — decision.** Uses the analyzer's `ai_config.requires_ai_api_key`
  signal plus direct source review. When detected and the project is not
  already on AI Hub, raises a single `AskUserQuestion`: `Use OpenDeploy AI
  Hub (Recommended)` / `Use my own AI keys` / `Continue without AI`. This
  step records the choice into the deploy-attempt record but performs no
  mutation — the project does not exist yet.

- **Step 9.5 — provision + local-file fill (only if step 6.25 chose AI Hub).**
  After the project is created (Step 8) and dependencies are provisioned
  (Step 9), the autoplan runs `opendeploy ai-hub keys provision --project
  <id> --environment <env> --show-secrets --json` to **explicitly** create
  the key. The response's real `key` value flows into a second
  `AskUserQuestion` covering local-file writes (write the AI Hub key into
  `.env` so `pnpm dev` works locally; `.env.example` gets the var name +
  base URL only, never the real key). Service body at Step 10 still uses
  the `{{OPENDEPLOY_AI_API_KEY}}` placeholder so future key rotations
  propagate server-side. Provision failures stop the deploy with a clear
  error — there is no silent fallback to lazy backend expansion.

For deeper operations on already-deployed projects (re-provision after a
rotation, top up credits, set auto-recharge, inspect usage, fully rewrite
an existing app's LLM call sites), the autoplan hands off here. Treat
that handoff as the primary entry point — most invocations arrive
mid-deploy or post-deploy with project context already resolved.

Otherwise pick this skill when the user wants to:

- Provision a fresh AI Hub key for a project / environment
- Check the remaining AI Hub credit balance
- Top up AI Hub credits (Stripe checkout) or set up auto-recharge
- See how many credits a model burned, broken down per model or per key
- List the models available through the AI Hub
- Get the OpenAI-compatible base URL + auth header format to paste into an SDK
- Deactivate or delete an AI Hub key (e.g. suspected leak)
- **Detect existing LLM call sites in the project and offer to migrate them
  to AI Hub** (see the *Migrating an existing app to AI Hub* section below)

Do NOT pick this skill for:

- **Setting `OPENDEPLOY_AI_API_KEY` into a service env** — the deploy flow
  auto-injects the AI Hub key when the service env contains the placeholder
  `{{OPENDEPLOY_AI_API_KEY}}` (or the legacy `{{MINIONS_AI_API_KEY}}`, kept
  for backwards compatibility) or a known AI SDK env var. Use `opendeploy-env`
  to add the placeholder, not this skill.
- **Initial deploy** — the deploy autoplan provisions an AI Hub key per
  project automatically. Only invoke this skill if the user wants to inspect
  or re-provision after deploy.
- **Project / service CRUD** → use `opendeploy` / `opendeploy-config`.
- **Stripe subscription billing (plans)** → not this skill. AI Hub credits
  are pay-as-you-go top-ups, independent of plan subscription.

## Capabilities

| Operation | Preferred CLI command | API fallback | Mutation? | Confirmation? |
|---|---|---|---|---|
| List keys | `opendeploy ai-hub keys list [--project <id>] [--environment <env>] [--include-deleted] --json` | `opendeploy api get /v1/aihub-keys --json` | no | no |
| Get one key | `opendeploy ai-hub keys get <key-id> --json` | `opendeploy api get /v1/aihub-keys/<key-id> --json` | no | no |
| Provision (create / re-create) | `opendeploy ai-hub keys provision --project <id> --environment <env> --json` | `opendeploy api post /v1/aihub-keys/recreate --data '{"project_id":"<id>","environment":"<env>"}' --json` | yes | YES if a previous active key exists for that project/env |
| Delete key record | `opendeploy ai-hub keys delete <key-id> --json` | `opendeploy api delete /v1/aihub-keys/<key-id> --json` | yes | YES |
| Deactivate by token name | `opendeploy ai-hub keys deactivate --token-name <name> --json` | `opendeploy api delete /v1/aihub-keys/by-token?token_name=<name> --json` | yes | YES |
| Balance | `opendeploy ai-hub credits balance --json` | `opendeploy api get /v1/ai-hub/user/self --json` | no | no |
| Top-up history | `opendeploy ai-hub credits history --json` | `opendeploy api get /v1/topup/history --json` | no | no |
| Transactions ledger | `opendeploy ai-hub credits transactions --json` | `opendeploy api get /v1/topup/transactions --json` | no | no |
| Latest top-up status | `opendeploy ai-hub credits latest --json` | `opendeploy api get /v1/topup/latest --json` | no | no |
| Create Stripe checkout | `opendeploy ai-hub credits checkout --amount <usd> --confirm-paid --json` | `opendeploy api post /v1/topup/checkout --data '{"amount":<usd>}' --confirm-paid --json` | yes | YES (paid action) |
| Get auto-recharge | `opendeploy ai-hub credits auto-recharge get --json` | `opendeploy api get /v1/topup/auto-recharge --json` | no | no |
| Set auto-recharge | `opendeploy ai-hub credits auto-recharge set --enabled true --threshold-amount 5 --recharge-amount 20 --json` | `opendeploy api put /v1/topup/auto-recharge --body auto-recharge.json --json` | yes | YES (turning on / changing cap) |
| Usage by model | `opendeploy ai-hub usage models [--start <ts>] [--end <ts>] --json` | `opendeploy api get /v1/ai-hub/usage/model --json` | no | no |
| Usage by key | `opendeploy ai-hub usage tokens --json` | `opendeploy api get /v1/ai-hub/usage/token --json` | no | no |
| Per-call logs | `opendeploy ai-hub usage logs [--limit 50] [--page 1] --json` | `opendeploy api get /v1/ai-hub/log/self --json` | no | no |
| Aggregated stats | `opendeploy ai-hub usage stats --json` | `opendeploy api get /v1/ai-hub/log/self/stat --json` | no | no |
| List models | `opendeploy ai-hub models list --json` | `opendeploy api get /v1/ai-hub/models --json` | no | no |
| Model metadata | `opendeploy ai-hub models metadata --json` | `opendeploy api get /v1/ai-hub/model-metadata --json` | no | no |
| Pricing (public) | `opendeploy ai-hub pricing --json` | `opendeploy api get /v1/ai-hub/pricing --public --json` | no | no |
| Base URL + auth header | `opendeploy ai-hub base-url --json` | local — no API call | no | no |

**CLI route compatibility.** The `opendeploy ai-hub` namespace is new. If
`opendeploy ai-hub <op>` exits with `unknown command` or `opendeploy routes
list --json` does not list an `ai-hub` group, fall back to the API column or
hand off to `opendeploy-setup` to update the CLI.

**DELETE policy reminder.** The global `opendeploy-api` skill blocks DELETE.
`ai-hub keys delete` and `ai-hub keys deactivate` are the only sanctioned
exceptions in this skill, and only when the named CLI command is not yet
available on the user's installed CLI. Always ask before issuing the fallback
DELETE call.

**Request body shapes** for the API fallback:

```json
// /v1/topup/checkout
{ "amount": 20, "success_url": "https://...", "cancel_url": "https://..." }

// /v1/topup/auto-recharge (PUT)
{
  "enabled": true,
  "threshold_amount": 5,
  "recharge_amount": 20,
  "max_monthly_amount": 200,
  "stripe_payment_method_id": "pm_..."
}

// /v1/aihub-keys/recreate
{ "project_id": "<uuid>", "environment": "staging" }
```

`amount`, `threshold_amount`, `recharge_amount`, and `max_monthly_amount` are
USD (numbers, not strings). `max_monthly_amount: 0` means no monthly cap.

## Mandatory structured confirmation

Every operation that spends money, replaces a live key, or removes a key
record MUST get explicit user approval BEFORE calling the CLI/API. Use the
host agent's structured question / approval UI when available
(`AskUserQuestion`, Codex user-input popup, or equivalent). Do not print a
plain `Confirm? yes/no` line and wait in chat when a structured UI exists.
Never chain confirmations into the same turn — the user gets one clear
approval choice.

### Provisioning a key when an active one already exists

```text
question: "Re-provision the AI Hub key for <project> / <env>?"
header:   "AI Hub key"
options:
  - label: "Re-provision and continue (Recommended)"
    description: "Creates a fresh AI Hub key and rotates it into the project's secrets. The old key stops working immediately — any service still using the cached value will fail until it picks up the new value on next restart/redeploy."
  - label: "Show what would change first"
    description: "List the affected project, environment, current key ID, and which services consume OPENDEPLOY_AI_API_KEY before changing anything."
  - label: "Cancel"
    description: "Stop without changing the key."
```

### Top-up (Stripe checkout)

```text
question: "Top up AI Hub credits with $<amount>?"
header:   "Paid action"
options:
  - label: "Create checkout link (Recommended)"
    description: "Generates a Stripe checkout URL for $<amount> USD. No charge happens until you complete checkout in the browser."
  - label: "Cancel"
    description: "Stop. No checkout link is created and no charge is attempted."
```

The recommended option triggers `opendeploy ai-hub credits checkout
--amount <amount> --confirm-paid`. The `--confirm-paid` flag is required —
the gateway's consent gate rejects the request without it.

### Auto-recharge enable / change

```text
question: "Enable auto-recharge that adds $<recharge_amount> when balance drops below $<threshold>?"
header:   "Auto-recharge"
options:
  - label: "Enable auto-recharge (Recommended)"
    description: "OpenDeploy will charge the saved Stripe payment method up to $<max_monthly_amount>/month when the AI Hub balance falls under $<threshold>. You can disable it any time."
  - label: "Adjust limits first"
    description: "Show the current threshold, recharge amount, and monthly cap before enabling."
  - label: "Cancel"
    description: "Stop. Auto-recharge stays in its current state."
```

### Delete / deactivate a key

```text
question: "Deactivate AI Hub key <token_name>?"
header:   "AI Hub key"
options:
  - label: "Deactivate (Recommended)"
    description: "The key stops accepting requests immediately. Any service still using it will fail until rotated. This cannot be reversed — re-provisioning gives a new key, not the old value."
  - label: "Cancel"
    description: "Stop without deactivating."
```

`list`, `get`, `balance`, `history`, `transactions`, `latest`, all `usage`
queries, `models list`, `models metadata`, `pricing`, and `base-url` proceed
without confirmation. They are all read-only.

## Provisioning a key (first time on a project)

1. Confirm the project ID:
   `opendeploy projects list --json` and pick by name, OR pass `--project
   <project-id>` if the user already named one.
2. Pick the environment. AI Hub keys are scoped per-environment so staging
   spend stays separate from production:
   ```text
   question: "Which environment is the key for?"
   options:
     - label: "production (Recommended)"
       description: "Use for live customer traffic. Reads/writes to the production AI Hub budget."
     - label: "staging"
       description: "Use for pre-production. Reads/writes the staging budget when staging is enabled; otherwise shares the production budget."
   ```
3. Provision:
   `opendeploy ai-hub keys provision --project <id> --environment <env>
   --json`
4. The response includes:
   - `key`: the actual `Bearer` token. Treat as a secret — print only when
     the user explicitly asks. Do NOT echo it into logs or commit it.
   - `key_propagated: true|false` — whether the new value was written into
     project secrets that reference `{{OPENDEPLOY_AI_API_KEY}}` (or the
     legacy `{{MINIONS_AI_API_KEY}}`). If `false`, the
     deploy flow will pick it up on next deploy; warn the user that running
     services will fail until then.
5. Surface the base URL the user needs to point their SDK at:
   `opendeploy ai-hub base-url --json`. The response is the constant
   `{"base_url":"https://api.opendeploy.dev/v1","protocol":"OpenAI-compatible","auth_header":"Authorization: Bearer <ai-hub-key>"}`.

## Topping up credits

OpenDeploy AI Hub is metered. Each top-up is a Stripe checkout: the CLI
returns a URL, the user completes payment in the browser, then `credits
latest` flips to `succeeded` after Stripe webhook confirms.

1. Check current balance first:
   `opendeploy ai-hub credits balance --json`. The response includes
   `quota` (raw quota units), `used_quota`, and (when available)
   `quota_dollars` derived from the AI Hub conversion (500000 quota units
   = $1 USD). Always report USD to the user, never raw quota.
2. Confirm with the structured approval above (Top-up).
3. Create the checkout session:
   `opendeploy ai-hub credits checkout --amount <usd> --confirm-paid
   --json`. Response includes `session_url` — open in browser.
4. After the user reports they completed checkout, poll:
   `opendeploy ai-hub credits latest --json` until `status: "succeeded"`.
   Do not retry checkout while the previous session is still `pending` —
   the user may complete it shortly.

## Auto-recharge

Auto-recharge keeps an app from running out of credits mid-call. It needs:

- A saved Stripe payment method (`stripe_payment_method_id`). The user gets
  this by completing at least one manual top-up checkout first; the dashboard
  Account → Payment Methods page surfaces saved cards.
- A threshold (e.g. $5) and a recharge amount (e.g. $20).
- Optionally a monthly cap (`max_monthly_amount`); 0 means unlimited.

Enable / change via:

```bash
opendeploy ai-hub credits auto-recharge set \
  --enabled true \
  --threshold-amount 5 \
  --recharge-amount 20 \
  --max-monthly-amount 200 \
  --stripe-payment-method-id pm_... \
  --json
```

Disable:

```bash
opendeploy ai-hub credits auto-recharge set --enabled false --json
```

If the user doesn't have a saved payment method yet, do not invent one —
ask them to complete one manual top-up first, then re-run.

## Inspecting usage

For "where did my credits go?" questions:

```bash
opendeploy ai-hub usage models --json    # top spend by model
opendeploy ai-hub usage tokens --json    # spend per AI Hub key (per project)
opendeploy ai-hub usage stats --json     # aggregate (call count, total quota)
opendeploy ai-hub usage logs --limit 50 --json   # raw per-call logs
```

The `usage logs` response includes refund/system rows; filter to `type:
"consume"` and `type: "error"` if the user only wants call activity.

Always convert quota to USD before reporting:

```text
1 USD = 500000 quota units
```

## Migrating an existing app to AI Hub

The headline AI Hub value prop: an app that already calls OpenAI / Anthropic /
Gemini / Cohere / Mistral / Groq / xAI / DeepSeek / Together / OpenRouter
can usually switch to AI Hub with one env value change + one line of code,
and inherit shared credits, usage tracking, auto-recharge, and the existing
project key lifecycle.

This section is the runbook. Do every step in order; do not skip the
detect / inventory / approval stages.

### Step 1 — Detect

Scan the project for LLM call sites before asking anything. Use the
Grep / Glob tools, not a fresh `find` shell. Run these searches in
parallel:

```text
1. Package / module references
   pattern: \b(openai|anthropic|@anthropic-ai/sdk|@google/(generative-ai|genai)|google\.generativeai|cohere(-ai)?|mistralai|groq(-sdk)?|together(-ai)?|replicate|@ai-sdk/(openai|anthropic|google|cohere|mistral|groq|perplexity|xai|deepseek|togetherai)|@langchain/(openai|anthropic|google-genai|cohere|mistralai|groq)|langchain[_-]?openai|langchain[_-]?anthropic|litellm|llama[_-]?index)\b
   include globs: *.ts, *.tsx, *.js, *.jsx, *.mjs, *.cjs, *.py, *.go, *.rb, *.php, *.java, *.kt, *.cs
   exclude globs: node_modules/**, .venv/**, venv/**, __pycache__/**, dist/**, build/**, .next/**, out/**, target/**, *.test.*, *.spec.*

2. Env var references in code
   pattern: \b(OPENAI|ANTHROPIC|GOOGLE_GENERATIVE_AI|GEMINI|GOOGLE|COHERE|MISTRAL|GROQ|XAI|DEEPSEEK|TOGETHER|OPENROUTER|PERPLEXITY|FIREWORKS|REPLICATE)_API_(KEY|TOKEN|BASE|BASE_URL)\b
   (same include / exclude as above)

3. Env files
   include globs: .env, .env.*, *.env
   pattern: same env-var regex as #2

4. Hardcoded provider base URLs
   pattern: \b(api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|api\.cohere\.com|api\.mistral\.ai|api\.groq\.com|api\.x\.ai|api\.deepseek\.com|api\.together\.xyz|api\.replicate\.com|openrouter\.ai|api\.perplexity\.ai|api\.fireworks\.ai)\b

5. Dependency manifests (read full file)
   files: package.json, pyproject.toml, requirements.txt, Pipfile, go.mod, Gemfile, composer.json, build.gradle, pom.xml
   keywords: same package names as #1
```

Skip any hit where the surrounding code makes it clear the caller is
already pointing at AI Hub (`api.opendeploy.dev`, `OPENDEPLOY_AI_API_KEY`,
`MINIONS_AI_API_KEY`,
or a comment marking it as already-migrated).

### Step 2 — Categorize and present the inventory

Group hits into three buckets:

- **Auto-migratable** — OpenAI SDK callsites (Node `openai`, Python `openai`,
  `@ai-sdk/openai`, `@langchain/openai`, `langchain-openai`, `litellm` with
  `openai/` model prefix). These can swap to AI Hub with a `baseURL` change.
- **Native SDK (manual)** — `@anthropic-ai/sdk`, `@google/generative-ai`,
  `cohere-ai`, `@mistralai/mistralai`, `groq-sdk` (when used as native
  client, not via `@ai-sdk/groq`), `replicate`, native LangChain provider
  classes (`@langchain/anthropic`, etc). AI Hub speaks OpenAI Chat
  Completions / Embeddings, NOT the vendor-specific wire formats. Report
  these but do not auto-rewrite — offer the manual recipe (switch to
  OpenAI SDK + AI Hub URL with the OpenAI-format model name like
  `claude-3-5-sonnet-20241022`).
- **Env-only** — env var is set but no SDK callsite found (e.g. only in
  `.env`, used by a binary the source doesn't ship). Treat as
  auto-migratable on the env-var side; flag that no code change is needed.

Then ask:

```text
question: "Migrate the project's LLM calls onto OpenDeploy AI Hub?"
header:   "AI Hub migration"
options:
  - label: "Migrate auto-migratable callsites (Recommended)"
    description: "Provision an AI Hub key for the project, point the <N> OpenAI-compatible callsites at https://api.opendeploy.dev/v1, sync the placeholder into OpenDeploy service env. Leaves the <M> native-SDK callsites alone — those need a manual switch to OpenAI SDK first."
  - label: "Migrate everything (including native SDKs)"
    description: "Also rewrite Anthropic / Gemini / Cohere SDK callsites to use the OpenAI SDK against AI Hub with mapped model names. Riskier — vendor-specific features (Anthropic prompt caching, Gemini safety settings, etc.) do not transfer."
  - label: "Show the inventory first"
    description: "Print every detected callsite with its file:line so I can choose what to migrate."
  - label: "Cancel"
    description: "Do not migrate. Leave source and env unchanged."
```

When showing the inventory, format as a short table per bucket:

```text
Auto-migratable (3):
  src/lib/openai.ts:12      new OpenAI({ apiKey: process.env.OPENAI_API_KEY })
  src/api/chat.py:5         OpenAI(api_key=os.environ["OPENAI_API_KEY"])
  src/ai.ts:3               openai('gpt-4o') from @ai-sdk/openai

Native SDK — manual only (1):
  src/lib/claude.ts:8       new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY })

Env-only (1):
  .env.production           ANTHROPIC_API_KEY=sk-ant-...

Hardcoded provider URLs (0): none
```

### Step 3 — Provision the AI Hub key

If the user approved migration, provision the key for the project /
environment they pick. Use the existing **Provisioning a key** runbook
above. The response includes the `key` value and `key_propagated`.

If the project does not exist on OpenDeploy yet (no project ID resolvable
from `opendeploy context resolve --json`), pause and hand off to the
`opendeploy` deploy autoplan — AI Hub keys are project-scoped, you need a
project first. Do not silently create a project here.

### Step 4 — Apply code edits

Default convention (per user preference): **keep the existing env var
name, swap its value to the AI Hub key, add `baseURL` in the client
constructor.** No env-var renames in code. This minimises diff size and
lets the user roll back by changing the env value back.

Apply these patterns via Edit, one file at a time. Show the diff in chat
before applying when the file has more than one callsite.

**OpenAI SDK — Node / TypeScript**

```ts
// before
import OpenAI from 'openai'
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY })

// after
import OpenAI from 'openai'
const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  baseURL: 'https://api.opendeploy.dev/v1',
})
```

**OpenAI SDK — Python**

```py
# before
from openai import OpenAI
client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

# after
from openai import OpenAI
client = OpenAI(
    api_key=os.environ["OPENAI_API_KEY"],
    base_url="https://api.opendeploy.dev/v1",
)
```

(Python's `openai>=1.0` also auto-reads `OPENAI_BASE_URL` from the
environment, so an alternative is to set that env var and leave code
alone. Use whichever the codebase already prefers.)

**Vercel AI SDK (`@ai-sdk/openai`)**

```ts
// before
import { openai } from '@ai-sdk/openai'
const result = await generateText({ model: openai('gpt-4o') })

// after
import { createOpenAI } from '@ai-sdk/openai'
const aiHub = createOpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  baseURL: 'https://api.opendeploy.dev/v1',
})
const result = await generateText({ model: aiHub('gpt-4o') })
```

**LangChain — Node**

```ts
// before
import { ChatOpenAI } from '@langchain/openai'
const model = new ChatOpenAI({ apiKey: process.env.OPENAI_API_KEY, modelName: 'gpt-4' })

// after
const model = new ChatOpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  modelName: 'gpt-4',
  configuration: { baseURL: 'https://api.opendeploy.dev/v1' },
})
```

**LangChain — Python**

```py
# before
from langchain_openai import ChatOpenAI
model = ChatOpenAI(model="gpt-4")

# after
model = ChatOpenAI(model="gpt-4", base_url="https://api.opendeploy.dev/v1")
```

**LiteLLM**

```py
# before
response = litellm.completion(model="gpt-4", messages=[...])

# after — route through the OpenAI provider against AI Hub
response = litellm.completion(
    model="openai/gpt-4",
    api_base="https://api.opendeploy.dev/v1",
    api_key=os.environ["OPENAI_API_KEY"],
    messages=[...],
)
```

**Native SDK — DO NOT auto-rewrite, only print the manual recipe**

```text
@anthropic-ai/sdk / google.generativeai / cohere / native SDK callsite at <file:line>
  → To migrate, replace the import with `openai` (or `@ai-sdk/openai`),
    update the model string to AI Hub's OpenAI-format name (check with
    `opendeploy ai-hub models list --json`), and pass
    baseURL: 'https://api.opendeploy.dev/v1'. The vendor SDK's
    non-chat-completions features (Anthropic prompt caching, Gemini
    safety settings, Cohere rerank, etc.) won't transfer — review per
    callsite before migrating.
```

If the user picked "Migrate everything", still pause at each native-SDK
callsite, show the proposed rewrite + the lost-features warning, and
confirm one more time before editing.

### Step 5 — Sync OpenDeploy service env

After code edits land, push the env values into the deployed service so
the runtime picks up the AI Hub key on next deploy. Use the placeholder
form — never paste the raw key into a `--set` flag.

1. Resolve project + service + environment:
   `opendeploy context resolve --json`. If the resolution does not include
   a service ID, ask the user which service the migrated code runs in.
2. Patch the service env additively (one call per affected env var):
   ```bash
   opendeploy services env patch <project-id> <service-id> \
     --environment <env> \
     --set OPENAI_API_KEY={{OPENDEPLOY_AI_API_KEY}} \
     --json
   ```
   Repeat for every other auth env var that the migrated callsites read
   (e.g. `ANTHROPIC_API_KEY` if the user opted to migrate native SDKs too,
   `GROQ_API_KEY` for `@ai-sdk/groq`, etc.). The backend's AI Hub
   expansion resolves `{{OPENDEPLOY_AI_API_KEY}}` to the project's current
   AI Hub key at deploy time — so the value rotates automatically when
   the key is re-provisioned, and no raw token ever lives in the env
   table.
3. (Optional) For Python apps that rely on `OPENAI_BASE_URL` env-var
   auto-discovery instead of in-code `base_url=`:
   ```bash
   opendeploy services env patch <project-id> <service-id> \
     --environment <env> \
     --set OPENAI_BASE_URL=https://api.opendeploy.dev/v1 \
     --json
   ```
4. Mirror the change in the local `.env.example` (and `.env` if the user
   keeps one) so local dev matches:
   ```env
   # for OpenDeploy deploys the value is auto-injected; for local dev,
   # paste your AI Hub key from `opendeploy ai-hub keys provision ...`
   OPENAI_API_KEY=
   # uncomment to use AI Hub locally too
   # OPENAI_BASE_URL=https://api.opendeploy.dev/v1
   ```
   Never write a real key value into `.env.example` or any committed file.

### Step 6 — Verify and redeploy

1. Confirm the service env was updated:
   `opendeploy services env get <project-id> <service-id> --json` —
   look for the new keys with `value_redacted: true` (or whatever the
   server returns; never echo the raw value).
2. Tell the user a redeploy is needed for running pods to pick up the new
   key:
   ```bash
   opendeploy deployments create --project <id> --service <id> --environment <env>
   ```
   (Or hand off to the `opendeploy` deploy autoplan if the user prefers
   the guided flow.)
3. After redeploy, recommend a sanity check call. Pick one migrated
   callsite, ask the user to trigger the relevant endpoint, then:
   ```bash
   opendeploy ai-hub usage logs --limit 5 --json
   ```
   should show the call. If usage logs stay empty, hand off to
   `opendeploy-debug` with the deployment ID — the app is probably still
   pointing at the old provider URL or the env didn't propagate.

### Migration-specific failure modes

| Symptom | Cause | Resolution |
|---|---|---|
| `401 invalid_api_key` from `api.opendeploy.dev` after migration | App still has the old provider key value in memory (env not refreshed) | Force a fresh deploy with `deployments create`; cached env on running pods does not auto-update |
| `404 model_not_found` after migration | App calls a model name AI Hub does not expose (e.g. a fine-tune ID, a vendor preview model) | Check `opendeploy ai-hub models list --json`; either pick a supported model or keep that specific callsite on the original provider |
| Some calls succeed, others 401 | Mixed env: code reads OPENAI_API_KEY in one place, ANTHROPIC_API_KEY in another, only one was synced | Run Step 5 for the other env var name(s) too |
| Native SDK still hits `api.anthropic.com` after "Migrate everything" | The agent rewrote one callsite but missed another import path | Re-run Step 1 (detect) and pick up the survivors |
| `usage logs` shows the call but with `quota: 0` and an error | Model is gated behind a higher plan, or the project has $0 balance | Top up with `ai-hub credits checkout`, enable auto-recharge, or pick a cheaper model |

## Limits

- **One bundled gateway.** The AI Hub speaks the OpenAI Chat Completions /
  Embeddings format. Apps that need vendor-specific SDK surfaces (e.g.
  Anthropic's `messages` endpoint, Google's Generative AI SDK with native
  Gemini auth) need to use those SDKs directly with the AI Hub key only if
  the SDK supports a custom base URL and OpenAI-compatible format. Confirm
  before assuming compatibility.
- **One credit pool per user.** Staging and production share the same wallet
  unless the user is on a plan that splits them — check `credits balance`
  response.
- **Soft delete.** `keys delete` and `keys deactivate` are reversible only
  via re-provisioning a NEW key — the original token value cannot be brought
  back.
- **Webhook lag.** `credits checkout` returns immediately with a session
  URL. Balance updates only after Stripe fires the success webhook, which
  is typically a few seconds but can take longer. Poll `credits latest`,
  do not assume failure on first miss.
- **Pricing endpoint is public.** Anyone can `GET /v1/ai-hub/pricing`
  without auth — that's how the landing page renders the price table. All
  other endpoints require a bearer token.
- **Rate limits / quota errors** surface as HTTP 429 or as `status:
  "insufficient_quota"` on chat completions. The CLI does not retry — the
  agent should top up (or enable auto-recharge) and ask the user before
  retrying.

## Failure modes

| Symptom | Cause | Resolution |
|---|---|---|
| `opendeploy ai-hub ...` → `unknown command` | CLI predates 0.1.15 | Hand off to `opendeploy-setup` to update; fall back to `opendeploy api get/post/...` in the meantime |
| `403 paid action requires consent` on checkout | `--confirm-paid` not passed | Re-ask the structured question, then re-run with `--confirm-paid` |
| `409 active key exists` on provision | Project/env already has an active key | Confirm re-provision via the structured question, then call provision again |
| Balance unchanged after checkout | Stripe webhook still pending | Wait 10–30s, re-check `credits latest`; if still `pending` after 5 min, hand off to `opendeploy-oncall` |
| `auto-recharge set` → `payment method required` | User has never completed a top-up | Run one manual `credits checkout` first, then retry |
| Service requests fail with 401 from `api.opendeploy.dev/v1` after re-provision | App is still using cached old key | Restart / redeploy the affected service so it picks up the rotated `OPENDEPLOY_AI_API_KEY` value |
| `usage models` returns empty array | New project with zero calls so far | Not an error — say "no AI Hub usage recorded yet" |

For deeper debugging (CLI behavior, plugin trust, broken installs), hand off
to `opendeploy-debug`. For platform-side issues (gateway timeouts, charge
not landing after 10+ minutes), hand off to `opendeploy-oncall`.
