---
name: cloudflare-secrets
description: Persist secrets safely by storing them as Cloudflare Worker secrets via the Admin UI (Cloudflare Access protected) or via Wrangler. Avoid writing secrets into the OpenClaw workspace/memory.
---

# Cloudflare Worker Secrets (Persistent)

If you tell OpenClaw a secret in chat, it may end up written to the workspace (notes/memory) and synced to R2. For durable + safer storage, keep secrets in Cloudflare as Worker secrets.

## Admin UI (recommended)

1. Open the Admin UI: `/_admin/`
2. Go to the `Secrets` panel
3. Enter:
   - `SECRET_NAME` (example: `CLOUDFLARE_API_TOKEN`)
   - secret value
4. Click `Save Secret`
5. Click `Restart Gateway` so the container picks up the new env var

Notes:
- Secret values are never displayed after saving.
- A `CLOUDFLARE_API_TOKEN` must be configured (as a Worker secret) for the UI to list/set secrets.

## CLI (Wrangler)

From your local repo:

```bash
npx wrangler secret put CLOUDFLARE_API_TOKEN
npx wrangler secret list
```

Then restart the gateway from `/_admin/` to apply changes.

