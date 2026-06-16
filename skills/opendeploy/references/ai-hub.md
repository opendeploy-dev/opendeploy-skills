# AI Hub detection and OpenDeploy AI Hub opt-in

OpenDeploy AI Hub is the bundled LLM gateway. It can provision a project-scoped
AI Hub token when the agent submits the exact placeholder value in service
runtime env:

```text
{{OPENDEPLOY_AI_API_KEY}}
```

The legacy placeholder `{{MINIONS_AI_API_KEY}}` is still accepted for
backwards compatibility but new flows should use the canonical name above.

The public base URL for OpenDeploy AI Hub is:

```text
https://api.opendeploy.dev/v1
```

It speaks the OpenAI Chat Completions / Embeddings wire format. Apps that use
native vendor SDKs (Anthropic `messages`, native Gemini, native Cohere) cannot
be routed through this URL by just swapping a base URL — they need to switch
to the OpenAI SDK first or stay on the original provider.

## Product contract

- The analyzer emits `ai_config` with:
  - `requires_ai_api_key`
  - `detected_providers`
  - `api_key_vars`
  - `base_url_vars`
- The dashboard's guided deploy defaults detected AI key vars to OpenDeploy AI
  Hub and sends `{{OPENDEPLOY_AI_API_KEY}}`.
- The backend expands that placeholder during project env save and service
  runtime-variable create/update. It provisions or reuses a project token,
  stores the real token securely, creates/updates AIHubKey tracking, and forces
  paired base URL vars to `https://api.opendeploy.dev/v1`.
- This is a runtime env contract. Do not rely on it for `build_variables`.

## Detection

Prefer the CLI/analyzer `ai_config` when present, then verify high-confidence
evidence locally:

- AI SDK dependencies or imports such as `openai`, `@ai-sdk/openai`,
  `@anthropic-ai/sdk`, `@google/generative-ai`, `@ai-sdk/google`,
  `@ai-sdk/anthropic`, `@openrouter/ai-sdk-provider`, `groq-sdk`, `mistralai`,
  `together-ai`, `cohere`, `replicate`, LangChain, LlamaIndex, or provider
  aliases surfaced by the analyzer.
- Env key names with provider prefixes and AI key suffixes, for example
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
  `GOOGLE_GENERATIVE_AI_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`,
  `MISTRAL_API_KEY`, `DEEPSEEK_API_KEY`, `TOGETHER_API_KEY`,
  `PERPLEXITY_API_KEY`, `DASHSCOPE_API_KEY`, `QWEN_API_KEY`, `ARK_API_KEY`, or
  `XAI_API_KEY`.
- Paired base URL keys such as `OPENAI_BASE_URL`, `OPENAI_API_BASE`,
  `ANTHROPIC_BASE_URL`, `GEMINI_BASE_URL`, `OPENROUTER_BASE_URL`, or any
  analyzer-provided `base_url_vars`.
- If an OpenAI-compatible key is detected but no base URL var is listed, verify
  whether the SDK/framework supports a standard base URL env (`OPENAI_BASE_URL`,
  `OPENAI_API_BASE`, provider-specific equivalent). Add a base URL var only with
  source/docs/SDK evidence; otherwise tell the user OpenDeploy AI Hub may not be
  routable for that app shape and offer user-owned keys.

Reduce false positives:

- Do not treat generic `GITHUB_TOKEN`, OAuth client secrets, webhook secrets,
  payment keys, SMTP passwords, storage keys, or unrelated `_TOKEN` values as
  AI Hub keys unless provider/package evidence ties them to AI.
- If an app supports many optional providers, include only keys that source,
  docs, env examples, or analyzer output mark as required for the selected
  deployment mode. Optional integrations can stay unset or use boot-safe
  placeholders only if the app boots without them.

## User question

When AI Hub usage is required or likely startup-critical, ask before cloud
mutation:

```text
question: "This project uses AI provider env keys: <KEYS>. How should OpenDeploy configure them?"
header:   "AI Hub"
options:
  - label: "Use OpenDeploy AI Hub"
    description: "Recommended. OpenDeploy provisions a project AI Hub token and wires the detected runtime vars; no provider key paste needed. One OpenAI-compatible base URL across many models, shared credits."
  - label: "Use my own AI keys"
    description: "You provide the real provider key values through the normal key-only env-upload flow."
  - label: "Continue without AI"
    description: "Only valid when source evidence says AI is optional for boot and the first smoke test."
```

If the app cannot boot without AI keys, replace `Continue without AI` with
`Pause before deploy`.

For deeper AI Hub operations (provision, top up credits, set auto-recharge,
inspect usage, fully migrate an existing app onto AI Hub including code
rewrites) hand off to the `opendeploy-ai-hub` skill — this reference just
covers the deploy-time opt-in decision.

## Applying the decision

The deploy autoplan splits AI Hub handling into two phases: **Step 6.25
records the user's decision** before the project exists, and **Step 9.5
executes provision + local-file fill** after the project is created but
before services create. The reason for the split: AI Hub keys are
project-scoped, so the project ID has to exist before `ai-hub keys provision`
can run.

### Step-by-step provisioning runbook (Step 9.5 execution)

**0. Skip conditions.** Stop immediately if the user chose `Use my own AI
keys` or `Continue without AI`, or if Step 6.25 found no AI provider keys.
The rest of this runbook runs only when the recorded decision is
`Use OpenDeploy AI Hub`.

**1. Explicit provision.**

```bash
opendeploy ai-hub keys provision \
  --project <project-id> \
  --environment <env> \
  --show-secrets \
  --json
```

Response shape:

```json
{
  "key": "sk-od-...",
  "key_propagated": false
}
```

- `key` — the real AI Hub bearer token. Treat as a secret. It flows from CLI
  stdout straight into local-file writes; never echo it into chat, never
  paste it into a service body, never store it in the deploy-attempt record.
- `key_propagated` — `true` when OpenDeploy already wrote the resolved value
  into existing project secrets (re-provision case); `false` on first
  provision.
- `--show-secrets` is required for the agent to receive the real `key`
  value. Without it the CLI redacts the response.

If provision fails (HTTP 4xx/5xx, network error, `quota_exceeded`):

- Do **not** fall back to the implicit-placeholder approach.
- Do **not** proceed to services create.
- Surface the exact error and offer the user `Retry`, `Switch to Use my own
  AI keys`, or `Cancel deploy`.

**2. Local-file fill — structured approval first.**

Before writing anything to the user's working tree, raise one
`AskUserQuestion`:

```text
question: "Write the AI Hub key into local .env so local dev also uses AI Hub?"
header:   "Local AI Hub fill"
options:
  - "Write to .env and .env.example (Recommended)"
    "For each detected AI key var: if .env has the key empty or missing,
     write the AI Hub token; if it already has a different real value, back
     up the old value to .env.<var>.backup (mode 0600) and overwrite. For
     base URL vars, set https://api.opendeploy.dev/v1. .env.example gets
     the same var names with empty / base-URL values (never the real key)."
  - "Only update .env.example, leave .env alone"
    "Useful when keeping your own provider key for local dev and routing
     to AI Hub only in production."
  - "Skip local files entirely"
    "Only update the OpenDeploy backend service env at Step 10."
```

**3. File-write rules (strict).**

- **Never** write the real AI Hub token into any committed file. Files
  matching `*.example`, `*.sample`, `*.template`, `README*`, or anything
  in the repo's documentation tree get only the var name + empty value
  for api keys, or the literal base URL for base URL vars.
- Real key values go only to `.env`, `.env.local`, `.env.development`, or
  `.env.production` — and only when those files are gitignored.
- **Before writing the real key**, read `.gitignore`. If `.env` is not
  ignored, raise an additional consent question: "your .env is not
  gitignored — writing the AI Hub key here means the next commit will
  leak it. Continue?" with options `Add to .gitignore and continue
  (Recommended)`, `Continue anyway`, `Skip .env write`.
- Set file mode to `0600` when writing a real key.
- Preserve trailing newline; preserve order of unrelated keys; insert new
  keys at the end of the file with a blank-line separator and an
  `# OpenDeploy AI Hub` comment line above them.

**4. Service body preparation (Step 10 input).**

Regardless of which local-file option the user picked at step 2, the
service body the agent passes to `services create` at Step 10 uses the
placeholder approach:

- Add each `ai_config.api_key_vars[]` key to `runtime_variables` with
  value `{{OPENDEPLOY_AI_API_KEY}}`.
- Add each `ai_config.base_url_vars[]` key to `runtime_variables` with
  value `https://api.opendeploy.dev/v1`.
- The backend recognises the already-provisioned key from step 1 above
  and reuses it instead of double-provisioning. The placeholder approach
  is preserved here so future key rotations propagate automatically.
- Never paste the real AI Hub token value into the service body.
- Keep all of this out of `build_variables` unless source evidence proves
  the same key is also read at build time. Even then, do not use the
  placeholder in build vars; ask for a user-provided build-time key or
  patch the build so AI calls happen at runtime.
- Mark the API key vars as sensitive in any local/body metadata when the
  shape supports it. Base URL vars are not secrets.
- If source evidence proves a standard provider base URL var is supported
  but the analyzer omitted it, add that key to `base_url_vars` before
  applying the managed choice and record the evidence.
- For existing services (redeploy), patch runtime env and create a new
  deployment. A restart is not a reliable way to refresh app-visible env.

**5. Update the deploy-attempt record.**

Set the `ai_hub` block to:

```json
{
  "ai_hub": {
    "requires_ai_api_key": true,
    "detected_providers": ["openai"],
    "api_key_vars": ["OPENAI_API_KEY"],
    "base_url_vars": ["OPENAI_BASE_URL"],
    "evidence": ["package @ai-sdk/openai", ".env.example lists OPENAI_API_KEY"],
    "user_choice": "opendeploy_ai_hub",
    "provisioned": true,
    "key_propagated": false,
    "local_files_written": [".env", ".env.example"],
    "runtime_variables_set": ["OPENAI_API_KEY", "OPENAI_BASE_URL"],
    "build_time_blockers": []
  }
}
```

`local_files_written` is an array of file paths the agent actually wrote
to during step 2 (empty array when the user picked `Skip local files
entirely`). Never store the resolved token value.

### Why the split between explicit provision and placeholder

- **Explicit provision (step 1) catches failures early.** Quota exceeded,
  upstream gateway unreachable, OpenDeploy account not provisioned, etc.
  all surface before `services create` commits any state. If provisioning
  were left to the backend's lazy expansion (the legacy behaviour), the
  service would be created with a literal `{{OPENDEPLOY_AI_API_KEY}}`
  string in its env and would crash at runtime with `401 invalid_api_key`.
- **Placeholder in the service body (step 4) preserves rotation.** When
  the AI Hub key is later rotated (manually or by re-provision), the
  backend resolves the placeholder to the new value across every service
  variable that references it. If the agent had written the raw key value
  into `runtime_variables` at creation time, rotation would not propagate.
- **Local-file write (step 2) is the user-visible part.** Real key in
  `.env` means `pnpm dev` / `python manage.py runserver` / etc. start
  using AI Hub immediately, not just the deployed copy.

For `Use my own AI keys`:

- Use the normal `opendeploy-env` key-only consent flow.
- Accept values via structured secret input or a local `0600` file/body.
- Never print provider key values.

For `Continue without AI`:

- Set no fake provider key unless the app specifically requires a syntactically
  valid placeholder and source evidence proves it will not call the provider
  during boot/smoke test.
- Record a caveat that AI features will fail until real or AI-Hub-managed AI
  env is configured and redeployed.

## Attempt record

Record AI Hub decisions with env key names only:

```json
{
  "ai_hub": {
    "requires_ai_api_key": true,
    "detected_providers": ["openai"],
    "api_key_vars": ["OPENAI_API_KEY"],
    "base_url_vars": ["OPENAI_BASE_URL"],
    "evidence": ["package @ai-sdk/openai", ".env.example lists OPENAI_API_KEY"],
    "user_choice": "opendeploy_ai_hub",
    "runtime_variables_set": ["OPENAI_API_KEY", "OPENAI_BASE_URL"],
    "build_time_blockers": []
  }
}
```
