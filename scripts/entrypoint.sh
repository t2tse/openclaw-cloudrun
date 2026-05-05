#!/bin/sh
set -e

# Substitute environment variables in the template

export MODEL_PRIMARY="${MODEL_PRIMARY:-litellm/gemini-3.1-pro-preview}"
export MODEL_FALLBACKS="${MODEL_FALLBACKS:-[\"litellm/gemini-3.1-flash-lite-preview\"]}"
export GATEWAY_AUTH_TOKEN="${GATEWAY_AUTH_TOKEN:-}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
export GATEWAY_BIND="${GATEWAY_BIND:-loopback}"

envsubst '$MODEL_PRIMARY,$MODEL_FALLBACKS,$GATEWAY_AUTH_TOKEN,$LITELLM_MASTER_KEY,$GATEWAY_BIND' < /app/openclaw.json.template > /app/openclaw.json

# Use persistent state dir on PVC so pairings survive pod restarts
STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
umask 077
mkdir -p "$STATE_DIR"

# Create compile cache directory for NODE_COMPILE_CACHE (Node.js v22.8+)
if [ -n "$NODE_COMPILE_CACHE" ]; then
  mkdir -p "$NODE_COMPILE_CACHE"
fi

# Merge template with existing config, preserving user-managed keys (e.g. channels)
if [ -f "$STATE_DIR/openclaw.json" ]; then
  # Preserve channels and pairing data added by the user via CLI/Control UI.
  # Template wins for infra keys (gateway, models, tools, agents, etc).
  # Filter out built-in tools (exec, nodes, etc.) that are not real plugins.
  jq -s '.[1] as $existing | .[0] * { channels: ($existing.channels // {}) } | .plugins.allow = ((.plugins.allow // []) + ($existing.plugins.allow // []) | unique | map(select(. != "exec" and . != "nodes")))' \
    /app/openclaw.json "$STATE_DIR/openclaw.json" > "$STATE_DIR/openclaw.json.tmp" \
    && mv "$STATE_DIR/openclaw.json.tmp" "$STATE_DIR/openclaw.json"
else
  cp /app/openclaw.json "$STATE_DIR/openclaw.json"
fi

# Safety check: gateway.bind must match exec VM deployment status.
# - With exec VMs (EXEC_VMS_ENABLED=true): MUST be "lan" for ILB and node host connectivity.
# - Without exec VMs (EXEC_VMS_ENABLED=false): SHOULD be "loopback" for better security.
# "auto" resolves to loopback-only which breaks kube-proxy forwarding.
# "all" is not a valid OpenClaw value and causes CrashLoopBackOff.
BIND_VALUE=$(jq -r '.gateway.bind // "missing"' "$STATE_DIR/openclaw.json")
EXPECTED_BIND="${GATEWAY_BIND:-loopback}"

if [ "$BIND_VALUE" != "$EXPECTED_BIND" ]; then
  echo "WARN: gateway.bind is '$BIND_VALUE', expected '$EXPECTED_BIND'. Fixing."
  jq --arg bind "$EXPECTED_BIND" '.gateway.bind = $bind' "$STATE_DIR/openclaw.json" > "$STATE_DIR/openclaw.json.tmp" \
    && mv "$STATE_DIR/openclaw.json.tmp" "$STATE_DIR/openclaw.json"
fi

# Pre-seed exec-approvals.json so the gateway doesn't create one with empty defaults
if [ ! -f "$STATE_DIR/exec-approvals.json" ] || [ "$(jq -r '.defaults.security // empty' "$STATE_DIR/exec-approvals.json" 2>/dev/null)" = "" ]; then
  # Preserve existing socket info if file exists
  if [ -f "$STATE_DIR/exec-approvals.json" ]; then
    jq '. * {"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}' \
      "$STATE_DIR/exec-approvals.json" > "$STATE_DIR/exec-approvals.json.tmp" \
      && mv "$STATE_DIR/exec-approvals.json.tmp" "$STATE_DIR/exec-approvals.json"
  else
    cat > "$STATE_DIR/exec-approvals.json" << 'EOFEA'
{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}
EOFEA
  fi
fi

# Pre-seed auth-profiles.json for google-vertex to use ADC (Application Default Credentials)
mkdir -p "$STATE_DIR/agents/main/agent"
if [ ! -f "$STATE_DIR/agents/main/agent/auth-profiles.json" ]; then
  cat > "$STATE_DIR/agents/main/agent/auth-profiles.json" << 'EOFAUTH'
{"google-vertex":{"authMode":"adc"}}
EOFAUTH
fi

# OpenClaw 2026.4.x blocks symlink traversal for security.
# Do NOT symlink $HOME/.openclaw — use OPENCLAW_STATE_DIR env var instead.
# The gateway and CLI both respect OPENCLAW_STATE_DIR for state resolution.

# Seed workspace files from image (only if not already present on PVC).
# EXEC_RULES.md is always overwritten — it's infra-managed, not user-managed.
WORKSPACE_DIR="/app/workspace"
if [ -d /app/workspace-seed ]; then
  cp -f /app/workspace-seed/EXEC_RULES.md "$WORKSPACE_DIR/EXEC_RULES.md" 2>/dev/null || true
  # Append exec rules to AGENTS.md if not already present
  if [ -f "$WORKSPACE_DIR/AGENTS.md" ]; then
    if ! grep -q "Exec on Node Hosts" "$WORKSPACE_DIR/AGENTS.md" 2>/dev/null; then
      printf '\n' >> "$WORKSPACE_DIR/AGENTS.md"
      cat /app/workspace-seed/EXEC_RULES.md >> "$WORKSPACE_DIR/AGENTS.md"
    fi
  fi
fi

# Cleanup old plugin-runtime-deps to prevent event loop blocking
# OpenClaw downloads plugin deps per version, but old versions accumulate on the PVC.
# Scanning 1GB+ of old node_modules can block the event loop for 20-40 seconds.
OPENCLAW_VERSION=$(node -e "console.log(require('/usr/local/lib/node_modules/openclaw/package.json').version)" 2>/dev/null || echo "unknown")
if [ "$OPENCLAW_VERSION" != "unknown" ] && [ -d "$STATE_DIR/plugin-runtime-deps" ]; then
  # Remove any plugin-runtime-deps directories that don't match current version
  find "$STATE_DIR/plugin-runtime-deps" -maxdepth 1 -type d -name "openclaw-*" ! -name "openclaw-${OPENCLAW_VERSION}-*" -exec rm -rf {} + 2>/dev/null || true
  echo "[entrypoint] Cleaned up old plugin runtime deps (current version: $OPENCLAW_VERSION)"
fi

# Start OpenClaw
GLOBAL_ROOT=$(npm root -g)

# Background: auto-approve pending node-host device pairings.
# Only enabled when execution VMs are deployed (EXEC_VMS_ENABLED=true).
# This background loop causes event loop blocking, so it's disabled when not needed.
if [ "${EXEC_VMS_ENABLED:-false}" = "true" ]; then
  echo "[entrypoint] Starting auto-pair background loop (exec VMs enabled)"
  (
    sleep 30  # wait for gateway to be ready
    while true; do
      # List pending requests, extract request IDs for node-role devices
      pending=$(node "$GLOBAL_ROOT/openclaw/dist/entry.js" devices list --json --timeout 60000 2>/dev/null || echo '{}')
      echo "$pending" | jq -r '.pending[]? | select(.role == "node") | .requestId' 2>/dev/null | while read -r req_id; do
        if [ -n "$req_id" ]; then
          echo "[auto-pair] approving node device: $req_id"
          node "$GLOBAL_ROOT/openclaw/dist/entry.js" devices approve "$req_id" --timeout 60000 2>/dev/null || true
        fi
      done

      # Push exec approval config to all connected node hosts (bypasses Windows file locking)
      EA_JSON='{"version":1,"defaults":{"security":"full","ask":"off","askFallback":"full"},"agents":{"main":{"security":"full","ask":"off"}}}'
      echo "$pending" | jq -r '.paired[]? | select(.role == "node") | .deviceId' 2>/dev/null | while read -r node_id; do
        if [ -n "$node_id" ]; then
          echo "$EA_JSON" | node "$GLOBAL_ROOT/openclaw/dist/entry.js" approvals set --node "$node_id" --stdin --timeout 60000 2>/dev/null || true
        fi
      done
      sleep 60
    done
  ) &
else
  echo "[entrypoint] Skipping auto-pair background loop (no exec VMs deployed)"
fi

node "$GLOBAL_ROOT/openclaw/dist/entry.js" gateway --port 18789
