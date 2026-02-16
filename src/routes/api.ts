import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { createAccessMiddleware } from '../auth';
import {
  ensureMoltbotGateway,
  findExistingMoltbotProcess,
  mountR2Storage,
  syncToR2,
  waitForProcess,
} from '../gateway';
import { R2_MOUNT_PATH } from '../config';

// CLI commands can take 10-15 seconds to complete due to WebSocket connection overhead
const CLI_TIMEOUT_MS = 20000;

function isValidSecretBindingName(name: string): boolean {
  // Conservative env-var naming; Cloudflare bindings accept broader names but this avoids surprises.
  return /^[A-Z][A-Z0-9_]{1,63}$/.test(name);
}

async function cloudflareApiRequest(
  params: {
    accountId: string;
    apiToken: string;
    method: string;
    path: string;
    body?: unknown;
  },
): Promise<{ ok: boolean; status: number; json: unknown; rawText: string }> {
  const url = `https://api.cloudflare.com/client/v4${params.path}`;
  const response = await fetch(url, {
    method: params.method,
    headers: {
      Authorization: `Bearer ${params.apiToken}`,
      'Content-Type': 'application/json',
    },
    body: params.body ? JSON.stringify(params.body) : undefined,
  });

  const rawText = await response.text();
  let json: unknown = {};
  try {
    json = JSON.parse(rawText) as unknown;
  } catch {
    // Some errors can return non-JSON; keep rawText for debugging.
  }

  return { ok: response.ok, status: response.status, json, rawText };
}

/**
 * API routes
 * - /api/admin/* - Protected admin API routes (Cloudflare Access required)
 *
 * Note: /api/status is now handled by publicRoutes (no auth required)
 */
const api = new Hono<AppEnv>();

/**
 * Admin API routes - all protected by Cloudflare Access
 */
const adminApi = new Hono<AppEnv>();

// Middleware: Verify Cloudflare Access JWT for all admin routes
adminApi.use('*', createAccessMiddleware({ type: 'json' }));

// GET /api/admin/devices - List pending and paired devices
adminApi.get('/devices', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // Ensure moltbot is running first
    await ensureMoltbotGateway(sandbox, c.env);

    // Run OpenClaw CLI to list devices
    // Must specify --url and --token (OpenClaw v2026.2.3 requires explicit credentials with --url)
    const token = c.env.MOLTBOT_GATEWAY_TOKEN;
    const tokenArg = token ? ` --token ${token}` : '';
    const proc = await sandbox.startProcess(
      `openclaw devices list --json --url ws://localhost:18789${tokenArg}`,
    );
    await waitForProcess(proc, CLI_TIMEOUT_MS);

    const logs = await proc.getLogs();
    const stdout = logs.stdout || '';
    const stderr = logs.stderr || '';

    // Try to parse JSON output
    try {
      // Find JSON in output (may have other log lines)
      const jsonMatch = stdout.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        const data = JSON.parse(jsonMatch[0]);
        return c.json(data);
      }

      // If no JSON found, return raw output for debugging
      return c.json({
        pending: [],
        paired: [],
        raw: stdout,
        stderr,
      });
    } catch {
      return c.json({
        pending: [],
        paired: [],
        raw: stdout,
        stderr,
        parseError: 'Failed to parse CLI output',
      });
    }
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// POST /api/admin/devices/:requestId/approve - Approve a pending device
adminApi.post('/devices/:requestId/approve', async (c) => {
  const sandbox = c.get('sandbox');
  const requestId = c.req.param('requestId');

  if (!requestId) {
    return c.json({ error: 'requestId is required' }, 400);
  }

  try {
    // Ensure moltbot is running first
    await ensureMoltbotGateway(sandbox, c.env);

    // Run OpenClaw CLI to approve the device
    const token = c.env.MOLTBOT_GATEWAY_TOKEN;
    const tokenArg = token ? ` --token ${token}` : '';
    const proc = await sandbox.startProcess(
      `openclaw devices approve ${requestId} --url ws://localhost:18789${tokenArg}`,
    );
    await waitForProcess(proc, CLI_TIMEOUT_MS);

    const logs = await proc.getLogs();
    const stdout = logs.stdout || '';
    const stderr = logs.stderr || '';

    // Check for success indicators (case-insensitive, CLI outputs "Approved ...")
    const success = stdout.toLowerCase().includes('approved');

    return c.json({
      success,
      requestId,
      message: success ? 'Device approved' : 'Approval failed',
      stdout,
      stderr,
      exitCode: proc.exitCode,
      error: success ? undefined : stderr || stdout || 'Approval failed',
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// POST /api/admin/devices/approve-all - Approve all pending devices
adminApi.post('/devices/approve-all', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // Ensure moltbot is running first
    await ensureMoltbotGateway(sandbox, c.env);

    // First, get the list of pending devices
    const token = c.env.MOLTBOT_GATEWAY_TOKEN;
    const tokenArg = token ? ` --token ${token}` : '';
    const listProc = await sandbox.startProcess(
      `openclaw devices list --json --url ws://localhost:18789${tokenArg}`,
    );
    await waitForProcess(listProc, CLI_TIMEOUT_MS);

    const listLogs = await listProc.getLogs();
    const stdout = listLogs.stdout || '';

    // Parse pending devices
    let pending: Array<{ requestId: string }> = [];
    try {
      const jsonMatch = stdout.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        const data = JSON.parse(jsonMatch[0]);
        pending = data.pending || [];
      }
    } catch {
      return c.json({ error: 'Failed to parse device list', raw: stdout }, 500);
    }

    if (pending.length === 0) {
      return c.json({ approved: [], message: 'No pending devices to approve' });
    }

    // Approve each pending device
    const results: Array<{ requestId: string; success: boolean; error?: string }> = [];

    for (const device of pending) {
      try {
        // eslint-disable-next-line no-await-in-loop -- sequential device approval required
        const approveProc = await sandbox.startProcess(
          `openclaw devices approve ${device.requestId} --url ws://localhost:18789${tokenArg}`,
        );
        // eslint-disable-next-line no-await-in-loop
        await waitForProcess(approveProc, CLI_TIMEOUT_MS);

        // eslint-disable-next-line no-await-in-loop
        const approveLogs = await approveProc.getLogs();
        const success = approveLogs.stdout?.toLowerCase().includes('approved');
        const stdout = approveLogs.stdout || '';
        const stderr = approveLogs.stderr || '';

        results.push({
          requestId: device.requestId,
          success,
          error: success ? undefined : stderr || stdout || 'Approval failed',
        });
      } catch (err) {
        results.push({
          requestId: device.requestId,
          success: false,
          error: err instanceof Error ? err.message : 'Unknown error',
        });
      }
    }

    const approvedCount = results.filter((r) => r.success).length;
    return c.json({
      approved: results.filter((r) => r.success).map((r) => r.requestId),
      failed: results.filter((r) => !r.success),
      message: `Approved ${approvedCount} of ${pending.length} device(s)`,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// GET /api/admin/storage - Get R2 storage status and last sync time
adminApi.get('/storage', async (c) => {
  const sandbox = c.get('sandbox');
  const hasCredentials = !!(
    c.env.R2_ACCESS_KEY_ID &&
    c.env.R2_SECRET_ACCESS_KEY &&
    c.env.CF_ACCOUNT_ID
  );

  // Check which credentials are missing
  const missing: string[] = [];
  if (!c.env.R2_ACCESS_KEY_ID) missing.push('R2_ACCESS_KEY_ID');
  if (!c.env.R2_SECRET_ACCESS_KEY) missing.push('R2_SECRET_ACCESS_KEY');
  if (!c.env.CF_ACCOUNT_ID) missing.push('CF_ACCOUNT_ID');

  let lastSync: string | null = null;

  // If R2 is configured, check for last sync timestamp
  if (hasCredentials) {
    try {
      // Mount R2 if not already mounted
      await mountR2Storage(sandbox, c.env);

      // Check for sync marker file
      const proc = await sandbox.startProcess(
        `cat ${R2_MOUNT_PATH}/.last-sync 2>/dev/null || echo ""`,
      );
      await waitForProcess(proc, 5000);
      const logs = await proc.getLogs();
      const timestamp = logs.stdout?.trim();
      if (timestamp && timestamp !== '') {
        lastSync = timestamp;
      }
    } catch {
      // Ignore errors checking sync status
    }
  }

  return c.json({
    configured: hasCredentials,
    missing: missing.length > 0 ? missing : undefined,
    lastSync,
    message: hasCredentials
      ? 'R2 storage is configured. Your data will persist across container restarts.'
      : 'R2 storage is not configured. Paired devices and conversations will be lost when the container restarts.',
  });
});

// POST /api/admin/storage/sync - Trigger a manual sync to R2
adminApi.post('/storage/sync', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    await ensureMoltbotGateway(sandbox, c.env);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json(
      {
        success: false,
        error: 'Gateway failed to start',
        details: errorMessage,
      },
      500,
    );
  }

  const result = await syncToR2(sandbox, c.env);

  if (result.success) {
    return c.json({
      success: true,
      message: 'Sync completed successfully',
      lastSync: result.lastSync,
    });
  } else {
    const status = result.error?.includes('not configured') ? 400 : 500;
    return c.json(
      {
        success: false,
        error: result.error,
        details: result.details,
      },
      status,
    );
  }
});

// POST /api/admin/gateway/restart - Kill the current gateway and start a new one
adminApi.post('/gateway/restart', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // Find and kill the existing gateway process
    const existingProcess = await findExistingMoltbotProcess(sandbox);

    if (existingProcess) {
      console.log('Killing existing gateway process:', existingProcess.id);
      try {
        await existingProcess.kill();
      } catch (killErr) {
        console.error('Error killing process:', killErr);
      }
      // Wait a moment for the process to die
      await new Promise((r) => setTimeout(r, 2000));
    }

    // Start a new gateway in the background
    const bootPromise = ensureMoltbotGateway(sandbox, c.env).catch((err) => {
      console.error('Gateway restart failed:', err);
    });
    c.executionCtx.waitUntil(bootPromise);

    return c.json({
      success: true,
      message: existingProcess
        ? 'Gateway process killed, new instance starting...'
        : 'No existing process found, starting new instance...',
      previousProcessId: existingProcess?.id,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// GET /api/admin/secrets - List Worker secret binding names (values are never returned)
adminApi.get('/secrets', async (c) => {
  const accountId = c.env.CF_ACCOUNT_ID;
  const apiToken = c.env.CLOUDFLARE_API_TOKEN;
  const scriptName = c.env.WORKER_NAME || 'arsas-molt-fun';

  if (!accountId) return c.json({ error: 'CF_ACCOUNT_ID is required' }, 400);
  if (!apiToken) return c.json({ error: 'CLOUDFLARE_API_TOKEN is required' }, 400);

  const { ok, status, json, rawText } = await cloudflareApiRequest({
    accountId,
    apiToken,
    method: 'GET',
    path: `/accounts/${accountId}/workers/scripts/${encodeURIComponent(scriptName)}/secrets`,
  });

  if (!ok) {
    return c.json(
      {
        error: 'Failed to list secrets from Cloudflare API',
        status,
        details: rawText || json,
      },
      502,
    );
  }

  // The CF API returns { success, result: [...] } where items include "name".
  const names: string[] = [];
  if (typeof json === 'object' && json !== null) {
    const maybeResult = (json as Record<string, unknown>).result;
    if (Array.isArray(maybeResult)) {
      for (const item of maybeResult) {
        if (typeof item === 'object' && item !== null) {
          const name = (item as Record<string, unknown>).name;
          if (typeof name === 'string') names.push(name);
        }
      }
    }
  }

  names.sort();
  return c.json({ secrets: names, workerName: scriptName });
});

// POST /api/admin/secrets - Create/update a Worker secret binding
adminApi.post('/secrets', async (c) => {
  const accountId = c.env.CF_ACCOUNT_ID;
  const apiToken = c.env.CLOUDFLARE_API_TOKEN;
  const scriptName = c.env.WORKER_NAME || 'arsas-molt-fun';

  if (!accountId) return c.json({ error: 'CF_ACCOUNT_ID is required' }, 400);
  if (!apiToken) return c.json({ error: 'CLOUDFLARE_API_TOKEN is required' }, 400);

  let body: { name?: string; value?: string } = {};
  try {
    body = (await c.req.json()) as { name?: string; value?: string };
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const secretName = (body.name || '').trim();
  const secretValue = body.value ?? '';

  if (!isValidSecretBindingName(secretName)) {
    return c.json(
      { error: 'Invalid secret name. Use A-Z, 0-9, underscore; start with a letter.' },
      400,
    );
  }
  if (!secretValue || secretValue.length === 0) {
    return c.json({ error: 'Secret value must not be empty.' }, 400);
  }

  // Cloudflare has had multiple shapes for this API across versions.
  // Try the "secret name in path" endpoint first; fall back to the older "/secrets" endpoint.
  const preferredPath = `/accounts/${accountId}/workers/scripts/${encodeURIComponent(
    scriptName,
  )}/secrets/${encodeURIComponent(secretName)}`;

  const fallbackPath = `/accounts/${accountId}/workers/scripts/${encodeURIComponent(scriptName)}/secrets`;

  const payload = { name: secretName, text: secretValue, type: 'secret_text' as const };

  let result = await cloudflareApiRequest({
    accountId,
    apiToken,
    method: 'PUT',
    path: preferredPath,
    body: payload,
  });

  if (!result.ok) {
    result = await cloudflareApiRequest({
      accountId,
      apiToken,
      method: 'PUT',
      path: fallbackPath,
      body: payload,
    });
  }

  if (!result.ok) {
    return c.json(
      {
        error: 'Failed to set secret via Cloudflare API',
        status: result.status,
        details: result.rawText || result.json,
      },
      502,
    );
  }

  return c.json({
    success: true,
    name: secretName,
    workerName: scriptName,
    message: 'Secret stored as a Worker secret. Restart the gateway to apply to the container.',
  });
});

// Mount admin API routes under /admin
api.route('/admin', adminApi);

export { api };
