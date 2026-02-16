#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

mkdir -p "$CONFIG_DIR"

is_dir_empty() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    # Returns 0 (true) if empty, 1 (false) if has entries
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================

should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    if [ ! -f "$R2_SYNC_FILE" ]; then
        # Bootstrap behavior: if neither side has a timestamp yet, still restore.
        # This covers the case where R2 has data from another tool/prefix but no .last-sync marker.
        if [ ! -f "$LOCAL_SYNC_FILE" ]; then
            echo "No sync timestamps found, will restore from R2"
            return 0
        fi

        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

# Check for backup data in new openclaw/ prefix first, then legacy clawdbot/ prefix
if [ -f "$BACKUP_DIR/openclaw/openclaw.json" ]; then
    # If we have no local config yet, always restore (bootstrap).
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No local config file, restoring from R2 backup at $BACKUP_DIR/openclaw..."
        cp -a "$BACKUP_DIR/openclaw/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    elif should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/openclaw..."
        cp -a "$BACKUP_DIR/openclaw/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    # Legacy backup format — migrate .clawdbot data into .openclaw
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No local config file, restoring from legacy R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        # Rename the config file if it has the old name
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from legacy R2 backup"
    elif should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        # Rename the config file if it has the old name
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from legacy R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Very old legacy backup format (flat structure)
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No local config file, restoring from flat legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from flat legacy R2 backup"
    elif should_restore_from_r2; then
        echo "Restoring from flat legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from flat legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore workspace from R2 backup if available (only if R2 is newer)
# This includes IDENTITY.md, USER.md, MEMORY.md, memory/, and assets/
WORKSPACE_DIR="/root/clawd"
OPENCLAW_WORKSPACE_DIR="$CONFIG_DIR/workspace"
WORKSPACE_BACKUP_DIR=""
if [ -d "$BACKUP_DIR/openclaw-workspace" ] && [ "$(ls -A $BACKUP_DIR/openclaw-workspace 2>/dev/null)" ]; then
    # Some older syncs accidentally nested as openclaw-workspace/workspace/<files>.
    # Prefer the nested folder if the top-level doesn't look like a workspace root.
    if [ -d "$BACKUP_DIR/openclaw-workspace/workspace" ] \
        && [ "$(ls -A $BACKUP_DIR/openclaw-workspace/workspace 2>/dev/null)" ] \
        && [ ! -d "$BACKUP_DIR/openclaw-workspace/memory" ]; then
        WORKSPACE_BACKUP_DIR="$BACKUP_DIR/openclaw-workspace/workspace"
    else
        WORKSPACE_BACKUP_DIR="$BACKUP_DIR/openclaw-workspace"
    fi
elif [ -d "$BACKUP_DIR/workspace" ] && [ "$(ls -A $BACKUP_DIR/workspace 2>/dev/null)" ]; then
    if [ -d "$BACKUP_DIR/workspace/workspace" ] \
        && [ "$(ls -A $BACKUP_DIR/workspace/workspace 2>/dev/null)" ] \
        && [ ! -d "$BACKUP_DIR/workspace/memory" ]; then
        WORKSPACE_BACKUP_DIR="$BACKUP_DIR/workspace/workspace"
    else
        WORKSPACE_BACKUP_DIR="$BACKUP_DIR/workspace"
    fi
fi

if [ -n "$WORKSPACE_BACKUP_DIR" ]; then
    # If local workspace is empty, always restore (bootstrap).
    if is_dir_empty "$WORKSPACE_DIR"; then
        echo "Local workspace is empty, restoring from $WORKSPACE_BACKUP_DIR..."
        mkdir -p "$WORKSPACE_DIR"
        cp -a "$WORKSPACE_BACKUP_DIR/." "$WORKSPACE_DIR/"
        echo "Restored workspace from R2 backup"
    elif should_restore_from_r2; then
        echo "Restoring workspace from $WORKSPACE_BACKUP_DIR..."
        mkdir -p "$WORKSPACE_DIR"
        cp -a "$WORKSPACE_BACKUP_DIR/." "$WORKSPACE_DIR/"
        echo "Restored workspace from R2 backup"
    fi
fi

# OpenClaw's agent runtime may expect workspace under /root/.openclaw/workspace.
# Mirror the restored workspace so tools like `read memory/...` resolve correctly.
mkdir -p "$OPENCLAW_WORKSPACE_DIR"
if ! is_dir_empty "$WORKSPACE_DIR" && is_dir_empty "$OPENCLAW_WORKSPACE_DIR"; then
    echo "Mirroring workspace into $OPENCLAW_WORKSPACE_DIR..."
    cp -a "$WORKSPACE_DIR/." "$OPENCLAW_WORKSPACE_DIR/"
elif ! is_dir_empty "$OPENCLAW_WORKSPACE_DIR" && is_dir_empty "$WORKSPACE_DIR"; then
    echo "Mirroring workspace into $WORKSPACE_DIR..."
    cp -a "$OPENCLAW_WORKSPACE_DIR/." "$WORKSPACE_DIR/"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
SKILLS_BACKUP_DIR=""
if [ -d "$BACKUP_DIR/openclaw-skills" ] && [ "$(ls -A $BACKUP_DIR/openclaw-skills 2>/dev/null)" ]; then
    SKILLS_BACKUP_DIR="$BACKUP_DIR/openclaw-skills"
elif [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    SKILLS_BACKUP_DIR="$BACKUP_DIR/skills"
fi

if [ -n "$SKILLS_BACKUP_DIR" ]; then
    # If local skills dir is empty, always restore (bootstrap).
    if is_dir_empty "$SKILLS_DIR"; then
        echo "Local skills directory is empty, restoring from $SKILLS_BACKUP_DIR..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$SKILLS_BACKUP_DIR/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    elif should_restore_from_r2; then
        echo "Restoring skills from $SKILLS_BACKUP_DIR..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$SKILLS_BACKUP_DIR/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    set +e
    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health
    ONBOARD_EXIT=$?
    set -e

    if [ "$ONBOARD_EXIT" -ne 0 ]; then
        echo "Onboard failed with exit code $ONBOARD_EXIT; continuing with minimal config patch"
    else
        echo "Onboard completed"
    fi
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    if (!fs.existsSync(configPath)) {
        console.log('Config file missing, creating a minimal config');
    } else {
        config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }
} catch (e) {
    console.log('Failed to parse config, starting with empty config:', e?.message || e);
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

config.gateway.controlUi = config.gateway.controlUi || {};
// Allow bypassing device pairing without putting the Worker into DEV_MODE.
// DEV_MODE is still honored for backward compatibility.
config.gateway.controlUi.allowInsecureAuth =
  process.env.OPENCLAW_ALLOW_INSECURE_AUTH === 'true' || process.env.OPENCLAW_DEV_MODE === 'true';

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"
echo "Env passthrough check (set/missing):"
for key in \
  OPENCLAW_GATEWAY_TOKEN MOLTBOT_GATEWAY_TOKEN OPENCLAW_ALLOW_INSECURE_AUTH OPENCLAW_DEV_MODE \
  R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME CF_ACCOUNT_ID \
  GEMINI_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN \
  GITHUB_PERSONAL_ACCESS_TOKEN
do
  if [ -n "${!key}" ]; then
    echo "  - $key: set"
  else
    echo "  - $key: missing"
  fi
done

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi
