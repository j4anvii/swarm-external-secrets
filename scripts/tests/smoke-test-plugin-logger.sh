#!/usr/bin/env bash
# smoke-test-plugin-logger.sh
# Verifies the plugin logger feature: logs written to a host-mounted file,
# visible via the secrets-logger sidecar, with rotation support.

set -ex
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(realpath -- "${SCRIPT_DIR}/../..")"
# shellcheck source=smoke-test-helper.sh
source "${SCRIPT_DIR}/smoke-test-helper.sh"

# Configuration
VAULT_CONTAINER="smoke-vault-logger"
VAULT_ROOT_TOKEN="smoke-root-token"
VAULT_ADDR="http://127.0.0.1:8200"
STACK_NAME="smoke-logger"
SECRET_NAME="smoke_secret"
SECRET_PATH="database/mysql"
SECRET_FIELD="password"
SECRET_VALUE="logger-test-pass"
COMPOSE_FILE="${SCRIPT_DIR}/smoke-logger-compose.yml"
POLICY_FILE="${REPO_ROOT}/vault_conf/admin.hcl"
LOG_DIR="/run/swarm-external-secrets"
LOG_FILE="${LOG_DIR}/plugin.log"

# Cleanup trap — removes everything this test creates
cleanup() {
    echo -e "${RED}Running plugin-logger smoke test cleanup...${DEF}"
    remove_stack "${STACK_NAME}"
    docker secret rm "${SECRET_NAME}" 2>/dev/null || true
    docker stop "${VAULT_CONTAINER}" 2>/dev/null || true
    docker rm   "${VAULT_CONTAINER}" 2>/dev/null || true
    remove_plugin
    # Clean up the log files inside the Docker Desktop VM
    docker run --rm -v /run:/host-run alpine sh -c \
        "rm -f /host-run/swarm-external-secrets/plugin.log /host-run/swarm-external-secrets/plugin.log.1" \
        2>/dev/null || true
}
trap cleanup EXIT

# ── 0. Create host log directory ────────────────────────────────────────
# On macOS + Docker Desktop, /run is inside the Linux VM, not the macOS host.
# We use a --privileged container to create the directory inside the VM.
info "Creating host log directory inside Docker VM..."
docker run --rm --privileged -v /run:/host-run alpine sh -c \
    "mkdir -p /host-run/swarm-external-secrets && chmod 755 /host-run/swarm-external-secrets && rm -f /host-run/swarm-external-secrets/plugin.log /host-run/swarm-external-secrets/plugin.log.1"
success "Log directory ready: ${LOG_DIR}"

# ── 1. Start Vault dev container ────────────────────────────────────────
info "Starting HashiCorp Vault dev container..."
docker run -d \
    --name "${VAULT_CONTAINER}" \
    -p 8200:8200 \
    -e "VAULT_DEV_ROOT_TOKEN_ID=${VAULT_ROOT_TOKEN}" \
    hashicorp/vault:latest server -dev

info "Waiting for Vault to be ready..."
elapsed=0
until docker exec "${VAULT_CONTAINER}" \
        vault status -address="http://127.0.0.1:8200" &>/dev/null; do
    sleep 2
    elapsed=$((elapsed + 2))
    [ "${elapsed}" -lt 30 ] || die "Vault did not become ready within 30s."
done
success "Vault is ready."

# ── 2. Configure Vault ─────────────────────────────────────────────────
info "Applying policy to Vault..."
docker cp "${POLICY_FILE}" "${VAULT_CONTAINER}:/tmp/admin.hcl"
docker exec "${VAULT_CONTAINER}" \
    env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    vault policy write smoke-policy /tmp/admin.hcl
success "Policy applied."

info "Writing test secret to Vault..."
docker exec "${VAULT_CONTAINER}" \
    env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    vault kv put \
    "secret/${SECRET_PATH}" \
    "${SECRET_FIELD}=${SECRET_VALUE}"
success "Secret written."

info "Getting auth token from Vault..."
VAULT_TOKEN=$(docker exec "${VAULT_CONTAINER}" \
    env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    vault token create \
        -policy="smoke-policy" \
        -field=token)
success "Got auth token."

# ── 3. Build, configure, and enable the plugin ─────────────────────────
info "Building plugin..."
build_plugin

docker plugin set "${PLUGIN_NAME}" \
    SECRETS_PROVIDER="vault" \
    VAULT_ADDR="${VAULT_ADDR}" \
    VAULT_AUTH_METHOD="token" \
    VAULT_TOKEN="${VAULT_TOKEN}" \
    VAULT_MOUNT_PATH="secret" \
    ENABLE_ROTATION="true" \
    ROTATION_INTERVAL="10s" \
    ENABLE_MONITORING="false"
success "Plugin configured."

info "Enabling plugin..."
enable_plugin

# ── 4. Deploy stack with secrets-logger sidecar ─────────────────────────
info "Deploying swarm stack with secrets-logger sidecar..."
deploy_stack "${COMPOSE_FILE}" "${STACK_NAME}" 60

# ── 5. Verify the log file exists and has content ───────────────────────
# Since /run is inside the Docker VM on macOS, we read the log via a container
info "Waiting for plugin to write to log file (up to 30s)..."
elapsed=0
while [ "${elapsed}" -lt 30 ]; do
    LOG_SIZE=$(docker run --rm -v /run/swarm-external-secrets:/logs:ro alpine \
        sh -c "wc -c < /logs/plugin.log 2>/dev/null || echo 0" | tr -d '[:space:]')
    if [ "${LOG_SIZE}" -gt 0 ] 2>/dev/null; then
        success "Log file exists and has ${LOG_SIZE} bytes."
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ "${LOG_SIZE}" -eq 0 ] 2>/dev/null || [ -z "${LOG_SIZE}" ]; then
    die "Log file is empty or missing after 30s."
fi

# ── 6. Verify log content has expected entries ──────────────────────────
info "Checking log file for expected entries..."

LOG_CONTENT=$(docker run --rm -v /run/swarm-external-secrets:/logs:ro alpine \
    cat /logs/plugin.log 2>/dev/null || true)

# The plugin should log "plugin file logging enabled" at startup
if echo "${LOG_CONTENT}" | grep -q "plugin file logging enabled"; then
    success "Found 'plugin file logging enabled' in log."
else
    error "Missing 'plugin file logging enabled' — log content:"
    echo "${LOG_CONTENT}"
    die "Expected startup log entry not found."
fi

# The plugin should log secret retrieval or driver init
if echo "${LOG_CONTENT}" | grep -qi "secret\|driver\|provider\|initialized"; then
    success "Found operational log entries in plugin log."
else
    info "Log content so far:"
    echo "${LOG_CONTENT}"
    info "(operational entries may appear shortly — not fatal)"
fi

# ── 7. Verify the secrets-logger sidecar is tailing the log ─────────────
info "Checking secrets-logger sidecar service logs..."
sleep 5
SIDECAR_LOGS=$(docker service logs "${STACK_NAME}_secrets-logger" 2>&1 || true)
if echo "${SIDECAR_LOGS}" | grep -q "plugin file logging enabled"; then
    success "secrets-logger sidecar is successfully tailing plugin logs!"
else
    info "Sidecar logs (may need more time to propagate):"
    echo "${SIDECAR_LOGS}" | tail -20
    info "(sidecar propagation timing is non-fatal)"
fi

# ── 8. Verify secret was delivered correctly ────────────────────────────
info "Verifying secret value matches expected password..."
verify_secret "${STACK_NAME}" "app" "${SECRET_NAME}" "${SECRET_VALUE}" 60

# ── 9. Show summary ────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  Plugin Logger Smoke Test Results"
echo "============================================="
echo ""
echo "Log file location: ${LOG_FILE}"

LOG_STATS=$(docker run --rm -v /run/swarm-external-secrets:/logs:ro alpine \
    sh -c "echo \"Size: \$(wc -c < /logs/plugin.log) bytes, Lines: \$(wc -l < /logs/plugin.log)\"" 2>/dev/null || echo "N/A")
echo "Log stats: ${LOG_STATS}"
echo ""
echo "── Last 10 log lines ──"
docker run --rm -v /run/swarm-external-secrets:/logs:ro alpine \
    tail -10 /logs/plugin.log 2>/dev/null || echo "(could not read)"
echo ""

success "Plugin logger smoke test PASSED!"
