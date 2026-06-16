---
name: opendeploy-volume
version: "0.0.20"
description: Manage persistent volumes on OpenDeploy services — add, list, resize (expand only), detach, restore, or hard-delete an orphaned volume. Use when the user says add volume, attach storage, persistent disk, persist data, mount a volume, resize disk, expand storage, detach volume, restore deleted volume, undelete volume, or "volume X is detached/orphaned/deletes in N days". Read this before mutating any volume — the first volume on an existing service triggers a destructive workload conversion with brief downtime, and the agent MUST surface that before applying.
user-invokable: true
---

# OpenDeploy Volume

This skill manages persistent volumes attached to OpenDeploy user services.
Volumes survive container restart and redeploy. They use node-local storage
(`local-path` StorageClass), single-attach (RWO). Read the **Limits** section
before promising any HA / cross-node / replica-shared semantics.

## Invocation Preflight

If this skill is invoked directly, first run the global CLI version gate unless
another OpenDeploy skill already did:

```bash
npm list -g @opendeploydev/cli --depth=0 --json
npm view @opendeploydev/cli version --json
opendeploy preflight . --json
```

If global is missing or older than npm latest, hand off to `opendeploy-setup`.
If the user skips the update, continue with the installed global CLI only when
it supports the needed volume commands. Do not use `npx` as a fallback runner.

## When to invoke

Pick this skill when the user wants to:

- Keep data across pod restarts ("don't lose my SQLite", "persist uploads")
- Expand a volume that's filling up
- Detach a volume from a service (soft-delete with 7-day grace window)
- Restore an orphaned volume back to a service (within the 7-day window)
- Hard-delete an orphaned volume immediately (skip the grace window)
- See what volumes a service has, where they mount, how big they are

Do NOT pick this skill for:

- **Build/start/port config** → use `opendeploy-config`
- **Managed Postgres/MySQL/MongoDB/Redis** → use `opendeploy-database` (those carry their own embedded storage)
- **Env vars / secrets** → use `opendeploy-env`
- **Object storage (S3-style buckets)** → not exposed as an OpenDeploy-managed
  resource yet. Keep the user on the OpenDeploy path: configure the app's
  existing S3/media env, continue with a clear local-file behavior note, pause,
  or engage OpenDeploy support through `opendeploy-oncall`.

## Capabilities

| Operation | Preferred CLI command | API fallback (use until CLI wraps these) | Mutation? | Confirmation? |
|---|---|---|---|---|
| List volumes on a service | `opendeploy volumes list --service <id> --json` | `opendeploy api get /v1/services/<id>/volumes --json` | no | no |
| Add a volume | `opendeploy volumes add --service <id> --name <name> --mount <path> --size <size> --json` | `opendeploy api post /v1/services/<id>/volumes --body volume.json --json` | yes | YES if first volume on existing service |
| Resize (expand only) | `opendeploy volumes resize <volume-id> --size <newSize> --json` | `opendeploy api patch /v1/volumes/<volume-id>/size --body size.json --json` | yes | YES |
| Detach (soft-delete) | `opendeploy volumes detach <volume-id> --json` | `opendeploy api delete /v1/volumes/<volume-id> --json` | yes | YES |
| Restore an orphaned volume | `opendeploy volumes restore <volume-id> --json` | `opendeploy api post /v1/volumes/<volume-id>/restore --json` | yes | NO |
| Hard-delete an orphaned volume | `opendeploy volumes delete <volume-id> --force --json` | `opendeploy api delete /v1/volumes/<volume-id>?force=true --json` | yes | YES |

**CLI route compatibility.** The `opendeploy volumes` namespace is new. If
`opendeploy volumes <op>` exits with `unknown command` or `opendeploy routes
list --json` does not list a `volumes` group, fall back to the API column.
The API surfaces above are stable backend routes.

**DELETE policy reminder.** The global `opendeploy-api` skill blocks DELETE.
Volume soft-detach (`DELETE /v1/volumes/:id`) and hard-delete (`?force=true`)
are the only sanctioned exceptions in this skill, and only when the named
`opendeploy volumes` command does not yet exist on the user's CLI. Always
ask before issuing the fallback DELETE call.

**Request body shapes** for the API fallback:

```json
// volume.json (POST /v1/services/:id/volumes)
{ "name": "data", "mount_path": "/var/lib/data", "size": "5Gi" }

// size.json (PATCH /v1/volumes/:id/size)
{ "size": "10Gi" }
```

The field is `size` and the value is a Kubernetes quantity string such as
`5Gi`. Do not send `size_gib`, `sizeGiB`, or a bare number; the backend will
return `volume size is required`.

## Mandatory structured confirmation

Every operation that triggers workload restart, pod replacement, or data
loss MUST get explicit user approval BEFORE calling the CLI/API. Use the host
agent's structured question / approval UI when available (`AskUserQuestion`,
Codex user-input popup, or equivalent). Do not print a plain `Confirm? yes/no`
line and wait in chat when a structured UI exists. Never chain confirmations
into the same turn — the user gets one clear approval choice.

Question shape:

```text
question: "Attach OpenDeploy volume?"
header:   "Volume"
options:
  - label: "Attach volume and continue (Recommended)"
    description: "Adds a persistent disk mounted at <path>. If this is the first volume on an existing service, OpenDeploy converts it to a stateful workload and the service may be unavailable for about 30 seconds."
  - label: "Review details first"
    description: "Show the target service, mount path, size, and workload-conversion consequence before changing anything."
  - label: "Cancel"
    description: "Stop without changing the service or volume."
```

If the runtime has no structured question capability, ask one concise chat
question with the same three choices; this is a runtime limitation, not the
preferred OpenDeploy UX.

Operations requiring explicit approval:

- **Add the first volume to an existing service** — triggers workload
  conversion (Deployment → StatefulSet). The service is unavailable for
  ~30 seconds while the old pod is terminated and the new pod with the PVC
  starts. The recommended structured option is `Attach volume and continue`.
- **Resize a volume** — patches the PVC. On `local-path` storage this is
  in-place metadata only and does not restart the pod, but other storage
  classes may. The recommended structured option is `Expand volume`.
- **Detach a volume** — the volume becomes orphaned and is retained for 7
  days, then the reaper deletes it. The service no longer mounts it. The
  recommended structured option is `Detach volume`.
- **Hard-delete an orphaned volume** (`--force`) — irreversible. Phrase:
  `Delete permanently` and put `unrecoverable` in the option description.

`list` and `restore` proceed without confirmation. Restore is reversible
(the user can detach again immediately).

## Adding the first volume to an existing service (workload conversion)

Walk the user through this carefully:

1. List existing volumes:
   `opendeploy api get /v1/services/<id>/volumes --json`.
   The response is `{"volumes": [...]}`. If any row has `status=active`,
   this is NOT the first volume — the workflow will issue an in-place
   StatefulSet rolling update instead of a destructive conversion. Skip the
   ~30s downtime warning in that case (mention only the standard rolling
   restart).
2. If the array is empty (or only `orphaned`/`deleted` rows), this IS the
   first active volume. Confirm with the structured approval from the
   confirmations section above. Wait for explicit approval. Then call
   `volumes add` (or the API fallback).
   If the response is `403 quota_exceeded`, do not try a smaller size by
   default. This is a plan/storage-cap gate, not a transient validation error.
   Ask with `Upgrade plan (Recommended)` first and return
   `https://dashboard.opendeploy.dev/settings` if chosen. Only retry
   with a smaller size when the user explicitly chooses resource adjustment.
   If the call returns a gateway 502/503/504 without a structured JSON body,
   do not assume it failed. Wait a few seconds and re-list volumes first; the
   row may already be active or pending.
3. The response includes:
   - `volume_id`: row UUID — keep this for follow-ups.
   - `workload_conversion: true|false` — the authoritative signal that the
     deploy workflow will (or won't) convert the workload. If your local
     check disagrees, **trust this field** and re-quote the consequence to
     the user before they make any further requests.
   - `deployment_id`: the workflow's deployment UUID. May be `null` if the
     trigger failed — see the `502 workflow_trigger_failed` row in the
     failure-modes table.
   - `pending_deploy: false` once the workflow has been started; `true`
     means the row exists but the K8s side has NOT been provisioned yet.
4. If `deployment_id` is set, follow it:
   `opendeploy deploy wait <deployment_id> --follow --json`.
5. Once the deploy reports success, re-list:
   `opendeploy api get /v1/services/<id>/volumes --json`. The new row
   should now show `status=active`, a non-empty `k8s_pvc_name`,
   `k8s_namespace`, and `cluster_id`. Empty `k8s_pvc_name` after a
   successful deploy is a writeback bug — hand off to `opendeploy-debug`.

If the workload conversion fails partway through (rare but possible —
quota denial, missing local-path StorageClass, image pull failure during
the new pod's start), the deploy workflow surfaces the failure in the
deployment log. Hand off to `opendeploy-debug` with the deployment ID.
The volume row stays — `restore` is not the right path; the user can
either retry `volumes add` (the duplicate-name check short-circuits it)
or `volumes detach --force` to clear the row.

## Resize semantics

- **Expansion only.** The CLI rejects shrink requests. To shrink, the user
  must detach + recreate at smaller size + manually migrate data.
- **Pod restart depends on storage backend.** On `local-path` (the only
  supported backend today), resize is a metadata update and the pod stays
  running. Other backends may require a rolling pod restart. The CLI
  output reports which path was taken.
- **Quota check is server-side.** A resize that would exceed the user's
  plan storage quota is rejected with HTTP 403; the CLI surfaces the
  current usage vs limit so the user knows whether to upgrade.

## Orphan + restore lifecycle

```
                  detach          7 days        reaper
  active  ───────────────────►  orphaned  ─────────────►  deleted
     ▲                            │
     │                            │ restore (within 7 days)
     └────────────────────────────┘
```

- `detach` (no `force`) moves a volume to `orphaned` immediately. The PVC
  is NOT deleted in K8s; the data sits on the node disk and continues to
  count against the user's storage quota until the reaper sweeps it. The
  response includes `status`, `orphaned_at`, and `expires_at` (which is
  `orphaned_at + 7 days`) — quote `expires_at` to the user so they know
  their deadline.
- `restore` brings an orphaned volume back to its original service. The
  backend enforces:
  - same service (built into the row),
  - same owner (`owner_uid` must match the caller — non-owners get
    `403 owner_mismatch`),
  - within the 7-day window (`410 orphan_expired` after).
- After 7 days the reaper hard-deletes the PVC and marks the row deleted.
  At that point the data is unrecoverable.
- `--force` (or `?force=true` on the DELETE) skips the 7-day window and
  deletes immediately. Irreversible. Active volumes cannot be force-deleted
  — the backend rejects with `400 force_requires_orphaned` and tells you
  to detach first.

**Verification after detach.** A successful `204`/`200` on detach only
confirms the DB transition. Re-list with
`opendeploy api get /v1/services/<id>/volumes --json` and confirm the row
shows `status=orphaned` with a non-null `orphaned_at` and `expires_at`.

## Quota and storage caps

Storage quota is per-plan (free / paid tiers). The API rejects creates and
expansions that would push total active+orphaned storage over the effective
plan cap, including active storage add-ons. When this happens, the CLI returns
a structured 403 body such as:

```
{
  "error": "quota_exceeded",
  "requested": "10Gi",
  "available": "5Gi",
  "exceeded_resources": [
    {"resource_type": "storage", "current": 115, "requested": 10, "limit": 120, "unit": "GB"}
  ],
  "available_addons": [
    {"display_name": "Storage add-on", "resource_type": "storage", "quantity": 100, "unit": "GB", "price": 10, "currency": "USD"}
  ]
}
```

Surface the storage current/requested/limit and any matching storage add-on
name, quantity, and price. If the backend returned 403 here, do not tell the
user "maybe add-ons were not counted" — they were already included in the
effective limit. Ask with `Upgrade plan (Recommended)` as the first option. If
the user chooses upgrade, return
`https://dashboard.opendeploy.dev/settings` exactly. Do not retry; do
not silently pick a smaller size.

## Limits (read before promising anything)

- **Storage is node-local** (`local-path` StorageClass). If the K8s node
  the pod is scheduled on goes down, the service is unhealthy until the
  node returns. Data is preserved on the node's disk during outage but is
  lost permanently if the node disk fails.
- **No backup or snapshot in v1.** Tell users to keep their own backups
  (export to object storage, dump database, etc.) for anything they can't
  afford to lose.
- **Single replica when volumes are present.** The platform pins
  `replicas=1` on any service with an active volume — both at volume-add
  time and at every subsequent deploy. A scale-up request via
  `services update --replicas 2` does NOT error today; it silently
  re-pins to 1 on the next reconcile. If the user reports their replica
  count not sticking, this is the reason; do not file a bug.
- **Expansion only, no shrink.** K8s does not natively support PVC shrink.
- **`requests.storage` is metadata, not a hard disk quota** on local-path.
  The K8s ResourceQuota tracks namespace-aggregate, but a single misbehaving
  pod can fill the node disk independent of its declared volume size.
  Monitoring node disk pressure is on the v2 roadmap.

## Failure modes the agent must surface to the user

These are the actual error codes the backend returns. Surface them verbatim;
do not paraphrase, retry silently, or pick a "smart" fallback.

| Status | `error` field | Meaning | Agent action |
|---|---|---|---|
| 400 | `cannot_shrink` | Requested resize is smaller than current | Explain expansion-only rule. To shrink, detach + recreate at smaller size + manually migrate data. |
| 400 | `not_active` | Tried to resize / detach a volume that isn't `status=active` | Re-list and pick a different volume |
| 400 | `not_orphaned` | Tried to restore a volume whose status isn't `orphaned` | Re-list to confirm current status |
| 400 | `force_requires_orphaned` | Tried `--force` (?force=true) on an active volume | Detach first (without `--force`), then issue the force-delete on the now-orphaned row |
| 403 | `quota_exceeded` | Total active+orphaned storage would exceed effective plan + add-on cap | Show `exceeded_resources[storage]` current/requested/limit and any matching storage `available_addons` quantity/price. Ask with `Upgrade plan (Recommended)` first; if chosen, return `https://dashboard.opendeploy.dev/settings`. Do NOT retry with smaller unless the user chooses resource adjustment. |
| 403 | `owner_mismatch` | Restore attempted by someone other than the original owner | Tell the user only the original owner can restore; surface the volume's `owner_uid` so the right account can be reached |
| 409 | `duplicate_name` | A live volume on this service already has this name | Pick a different name; do NOT add a numeric suffix automatically — names are user-meaningful |
| 409 | `duplicate_mount` | A live volume on this service already mounts at this path | Pick a different `mount_path` (e.g. `/var/lib/foo` vs `/data/foo`) |
| 410 | `orphan_expired` | Restore window passed (>7 days since detach); the reaper has either deleted or is about to | Tell the user the data is unrecoverable |
| 501 | `volume_workflow_not_wired` | Operator has NOT enabled `OPENDEPLOY_VOLUMES_ENABLED` on this deployment yet | Stop. Do NOT attempt the API directly. Tell the user this is an operator decision; engage `opendeploy-oncall` if they need it turned on. |
| 502 | `workflow_trigger_failed` | The volume row was created but the deploy workflow could not be started (Temporal unavailable, etc.) | Re-list first. If the row is already `active`, continue. If it is pending with no deployment, tell the user the row exists but the PVC has NOT been provisioned. Retry by calling `volumes add` again with the same payload — the duplicate-name check short-circuits the row creation, but the workflow trigger will be re-attempted. |
| 502/503/504 | no JSON body / gateway page | Gateway timed out or upstream was temporarily unavailable | Re-list volumes before retrying. Continue if the volume is present and `active`; retry once only if the list proves no row was created. |
| 503 | `worker_capability_missing` | The deployment workers on this cluster have not been upgraded to a version that handles volumes | Tell the user to retry in ~1 minute. If it persists across multiple retries, hand off to `opendeploy-oncall`. |
| 503 | `worker_capability_check_failed` | Transient DB error verifying worker readiness | Retry once after ~10 seconds; surface the error if it persists |

## What this skill does NOT do

- Encrypt-at-rest configuration (handled by storage backend, not this skill)
- Backup / snapshot / restore-from-backup (v2)
- Cross-region volume replication (v2+, dependent on storage backend swap)
- Volume sharing between services (single-attach only by design)
- Filesystem-level operations inside the volume (use `opendeploy-debug`'s
  exec into the pod for that)

## Routing fallbacks

- For build/start/port changes: `opendeploy-config`, not this skill
- For managed Postgres / MySQL / MongoDB / Redis: `opendeploy-database`
- For env vars / secrets: `opendeploy-env`
- For "the deploy failed midway": `opendeploy-debug` with the deployment ID
- For platform health / read-only inspection: `opendeploy-ops`
- For `501 volume_workflow_not_wired` or persistent `503 worker_capability_missing`
  (operator-side gates that this skill cannot flip): `opendeploy-oncall`
