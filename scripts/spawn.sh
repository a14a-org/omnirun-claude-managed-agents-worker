#!/bin/bash
set -euo pipefail

# spawn.sh — per-session sandbox launcher for Anthropic Managed Agents.
#
# Invoked by `ant beta:worker poll --on-work ./spawn.sh` once per claimed
# session. `ant` sets the per-session env vars in our environment:
#   ANTHROPIC_SESSION_ID
#   ANTHROPIC_WORK_ID
#   ANTHROPIC_BASE_URL
# and the org-level vars are inherited from the host poller:
#   ANTHROPIC_ENVIRONMENT_KEY
#   ANTHROPIC_ENVIRONMENT_ID
#
# This script:
#   1. Creates a fresh OmniRun microVM (templateID=claude-agent) via the local
#      API, with a pinned egress allowlist (api.anthropic.com + DNS + skills
#      CDN) and ONLY the ANTHROPIC_ENVIRONMENT_* / per-session env vars.
#   2. Starts `ant beta:worker run` inside the VM (background command).
#   3. Polls the command until the worker process exits.
#   4. Optionally downloads /mnt/session/outputs back to the host.
#   5. Deletes the sandbox.
#
# SECURITY: We deliberately forward ONLY the environment vars listed in
# SANDBOX_ENV below. The org key is ANTHROPIC_ENVIRONMENT_KEY (scoped to the
# environment, safe inside the sandbox). ANTHROPIC_API_KEY is NEVER forwarded.

# ----------------------------------------------------------------------------
# Configuration (override via env)
# ----------------------------------------------------------------------------
OMNIRUN_API="${OMNIRUN_API:-http://127.0.0.1:8080}"
OMNIRUN_API_KEY="${OMNIRUN_API_KEY:?OMNIRUN_API_KEY must be set (X-API-Key for the local OmniRun API)}"
TEMPLATE_ID="${OMNIRUN_TEMPLATE_ID:-claude-agent}"

# Concurrency cap: refuse to start a new sandbox if there are already this many
# active sandboxes for this template. Protects the single box from
# over-subscription (8GB RAM each → ~7 max on a 62GB box; cap below that).
MAX_CONCURRENT="${OMNIRUN_MAX_CONCURRENT:-5}"

# Where to copy session outputs on the host (optional; empty = skip download).
OUTPUTS_DEST="${OMNIRUN_OUTPUTS_DEST:-}"

# Poll cadence / ceiling.
POLL_INTERVAL_SECS="${OMNIRUN_POLL_INTERVAL:-5}"
MAX_RUNTIME_SECS="${OMNIRUN_MAX_RUNTIME:-7200}"

# Egress allowlist for the sandbox. Anthropic's API is required. We also pin a
# fixed public DNS resolver (so the in-VM resolver, 8.8.8.8/8.8.4.4, can answer)
# and the skills CDN host.
#
# TODO(verify-on-box): confirm the EXACT skills-download host during end-to-end
# verification (capture it from `ant` debug logs or a tcpdump while a session
# downloads skills) and replace the placeholder below. Until confirmed, skills
# downloads may be blocked by the allowlist.
ALLOW_DOMAINS_JSON='["api.anthropic.com"]'
ALLOW_IPS_JSON='["8.8.8.8","8.8.4.4"]'   # fixed DNS resolvers used by the VM
SKILLS_CDN_HOST="${ANTHROPIC_SKILLS_HOST:-}"   # e.g. "storage.googleapis.com" — TODO confirm
if [ -n "$SKILLS_CDN_HOST" ]; then
    ALLOW_DOMAINS_JSON="[\"api.anthropic.com\",\"${SKILLS_CDN_HOST}\"]"
fi

# ----------------------------------------------------------------------------
# Validate required env
# ----------------------------------------------------------------------------
: "${ANTHROPIC_ENVIRONMENT_KEY:?ANTHROPIC_ENVIRONMENT_KEY must be set by the host poller}"
: "${ANTHROPIC_ENVIRONMENT_ID:?ANTHROPIC_ENVIRONMENT_ID must be set by the host poller}"
: "${ANTHROPIC_SESSION_ID:?ANTHROPIC_SESSION_ID must be set by ant}"
: "${ANTHROPIC_WORK_ID:?ANTHROPIC_WORK_ID must be set by ant}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "spawn.sh: refusing to run — ANTHROPIC_API_KEY is set; it must never reach a sandbox" >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
api() {
    # api <METHOD> <PATH> [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -fsS -X "$method" "${OMNIRUN_API}${path}" \
            -H "X-API-Key: ${OMNIRUN_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        curl -fsS -X "$method" "${OMNIRUN_API}${path}" \
            -H "X-API-Key: ${OMNIRUN_API_KEY}"
    fi
}

log() { echo "spawn.sh[${ANTHROPIC_SESSION_ID}]: $*" >&2; }

# ----------------------------------------------------------------------------
# Concurrency cap
# ----------------------------------------------------------------------------
ACTIVE=$(api GET /sandboxes | jq "[.[] | select(.template_id == \"${TEMPLATE_ID}\")] | length" 2>/dev/null || echo 0)
if [ "$ACTIVE" -ge "$MAX_CONCURRENT" ]; then
    log "concurrency cap reached (${ACTIVE}/${MAX_CONCURRENT} active ${TEMPLATE_ID} sandboxes); refusing session"
    exit 75   # EX_TEMPFAIL — signals ant this work could not be claimed now
fi

# ----------------------------------------------------------------------------
# 1. Create sandbox
# ----------------------------------------------------------------------------
# envVars carries ONLY the environment + per-session vars. NEVER the org API key.
CREATE_BODY=$(jq -n \
    --arg tid "$TEMPLATE_ID" \
    --argjson allow_domains "$ALLOW_DOMAINS_JSON" \
    --argjson allow_ips "$ALLOW_IPS_JSON" \
    --arg env_key "$ANTHROPIC_ENVIRONMENT_KEY" \
    --arg env_id "$ANTHROPIC_ENVIRONMENT_ID" \
    --arg session_id "$ANTHROPIC_SESSION_ID" \
    --arg work_id "$ANTHROPIC_WORK_ID" \
    --arg base_url "$ANTHROPIC_BASE_URL" \
    '{
        templateID: $tid,
        internet: true,
        network: {
            allowDomains: $allow_domains,
            allowIPs: $allow_ips
        },
        envVars: {
            ANTHROPIC_ENVIRONMENT_KEY: $env_key,
            ANTHROPIC_ENVIRONMENT_ID: $env_id,
            ANTHROPIC_SESSION_ID: $session_id,
            ANTHROPIC_WORK_ID: $work_id,
            ANTHROPIC_BASE_URL: $base_url
        },
        metadata: {
            anthropic_session_id: $session_id,
            anthropic_work_id: $work_id
        }
    }')

log "creating sandbox (template=${TEMPLATE_ID})"
CREATE_RESP=$(api POST /sandboxes "$CREATE_BODY")
SANDBOX_ID=$(echo "$CREATE_RESP" | jq -r '.sandboxID // .sandbox_id // .id')
if [ -z "$SANDBOX_ID" ] || [ "$SANDBOX_ID" = "null" ]; then
    log "failed to create sandbox: $CREATE_RESP"
    exit 1
fi
log "sandbox created: ${SANDBOX_ID}"

# Ensure we always tear the sandbox down, even on error.
cleanup() {
    log "deleting sandbox ${SANDBOX_ID}"
    api DELETE "/sandboxes/${SANDBOX_ID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 2. Start the worker inside the VM (background)
# ----------------------------------------------------------------------------
RUN_BODY=$(jq -n '{
    command: "ant beta:worker run",
    background: true,
    cwd: "/workspace"
}')
log "starting worker inside sandbox"
RUN_RESP=$(api POST "/sandboxes/${SANDBOX_ID}/commands" "$RUN_BODY")
PID=$(echo "$RUN_RESP" | jq -r '.pid // empty')
if [ -z "$PID" ]; then
    log "failed to start worker: $RUN_RESP"
    exit 1
fi
log "worker started (pid=${PID})"

# ----------------------------------------------------------------------------
# 3. Poll until the worker process exits
# ----------------------------------------------------------------------------
ELAPSED=0
EXIT_CODE=0
while :; do
    if ! STATUS=$(api GET "/sandboxes/${SANDBOX_ID}/commands/${PID}"); then
        # The command/sandbox is no longer queryable (e.g. the sandbox was
        # deleted out from under us, or the agent restarted). Treat the worker
        # as finished rather than spinning; the EXIT trap handles teardown.
        log "command status unavailable (sandbox may be gone); treating worker as finished"
        EXIT_CODE=0
        break
    fi
    RUNNING=$(echo "$STATUS" | jq -r '.running // false' 2>/dev/null)
    if [ "$RUNNING" != "true" ]; then
        EXIT_CODE=$(echo "$STATUS" | jq -r '.exit_code // 0' 2>/dev/null)
        log "worker exited (exit_code=${EXIT_CODE})"
        break
    fi
    if [ "$ELAPSED" -ge "$MAX_RUNTIME_SECS" ]; then
        log "worker exceeded max runtime (${MAX_RUNTIME_SECS}s); tearing down"
        EXIT_CODE=124
        break
    fi
    sleep "$POLL_INTERVAL_SECS"
    ELAPSED=$((ELAPSED + POLL_INTERVAL_SECS))
done

# ----------------------------------------------------------------------------
# 4. Optionally download session outputs
# ----------------------------------------------------------------------------
if [ -n "$OUTPUTS_DEST" ]; then
    DEST_DIR="${OUTPUTS_DEST}/${ANTHROPIC_SESSION_ID}"
    mkdir -p "$DEST_DIR"
    log "downloading /mnt/session/outputs -> ${DEST_DIR}"
    LISTING=$(api GET "/sandboxes/${SANDBOX_ID}/files/list?path=/mnt/session/outputs" || echo '{}')
    # Listing shape varies; extract any entries that look like file paths/names.
    echo "$LISTING" | jq -r '
        (.. | objects | select(has("name") and (.type? != "dir")) | .name)? // empty
    ' 2>/dev/null | while read -r fname; do
        [ -z "$fname" ] && continue
        src="/mnt/session/outputs/${fname}"
        curl -fsS "${OMNIRUN_API}/sandboxes/${SANDBOX_ID}/files/download?path=${src}" \
            -H "X-API-Key: ${OMNIRUN_API_KEY}" \
            -o "${DEST_DIR}/${fname}" \
            && log "downloaded ${fname}" \
            || log "WARN: failed to download ${fname}"
    done
fi

# cleanup() runs on EXIT and deletes the sandbox.
# `exit` requires a numeric 0-255 argument; an empty/non-numeric EXIT_CODE
# (e.g. from a missing status response) would otherwise abort with
# "numeric argument required".
[[ "$EXIT_CODE" =~ ^[0-9]+$ ]] || EXIT_CODE=0
[ "$EXIT_CODE" -gt 255 ] && EXIT_CODE=$((EXIT_CODE % 256))
exit "$EXIT_CODE"
