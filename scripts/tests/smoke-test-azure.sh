#!/usr/bin/env bash

set -ex
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(realpath -- "${SCRIPT_DIR}/../..")"
# shellcheck source=smoke-test-helper.sh
source "${SCRIPT_DIR}/smoke-test-helper.sh"

# Configuration
LOCALSTACK_CONTAINER="smoke-localstack-azure"
LOCALSTACK_IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack-azure-alpha:latest}"
LOCALSTACK_PORT="${LOCALSTACK_PORT:-4567}"
LOCALSTACK_ENDPOINT="http://localhost:${LOCALSTACK_PORT}"
LOCALSTACK_AUTH_TOKEN="${LOCALSTACK_AUTH_TOKEN:-}"
AZURE_LOCALSTACK_ENDPOINT="${AZURE_LOCALSTACK_ENDPOINT:-${LOCALSTACK_ENDPOINT}}"
AZURE_RESOURCE_GROUP="smoke-rg"
AZURE_LOCATION="eastus"
AZURE_VAULT_NAME="smoke-vault"
STACK_NAME="smoke-azure"
SECRET_NAME="smoke_secret"
AZURE_SECRET_NAME="database-mysql"
SECRET_FIELD="password"
SECRET_VALUE="azure-smoke-pass-v1"
SECRET_VALUE_ROTATED="azure-smoke-pass-v2"
COMPOSE_FILE="${SCRIPT_DIR}/smoke-azure-compose.yml"
PLUGIN_AZURE_ACCESS_TOKEN="${AZURE_ACCESS_TOKEN:-localstack-smoke-token}"

# Helper to run azlocal against LocalStack Azure endpoint
azlocal_cmd() {
    AZURE_LOCALSTACK_ENDPOINT="${AZURE_LOCALSTACK_ENDPOINT}" azlocal "$@"
}

# Cleanup trap
cleanup() {
    echo -e "${RED}Running Azure Key Vault smoke test cleanup...${DEF}"
    remove_stack "${STACK_NAME}"
    docker secret rm "${SECRET_NAME}" 2>/dev/null || true
    docker stop "${LOCALSTACK_CONTAINER}" 2>/dev/null || true
    docker rm   "${LOCALSTACK_CONTAINER}" 2>/dev/null || true
    remove_plugin
}
trap cleanup EXIT

if [ -z "${LOCALSTACK_AUTH_TOKEN}" ]; then
    info "LOCALSTACK_AUTH_TOKEN is not set; skipping Azure smoke test."
    success "Azure Key Vault smoke test SKIPPED."
    exit 0
fi

# Validate prerequisites
if ! command -v azlocal >/dev/null 2>&1; then
    die "azlocal is required. Install with: localstack extensions install localstack-extension-azure-cli-local"
fi

# Start LocalStack Azure container (skip if already running on target endpoint, e.g. in CI)
if curl -s "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
    info "LocalStack Azure endpoint already running, skipping container start."
    LOCALSTACK_CONTAINER=""
else
    info "Starting LocalStack Azure container..."
    docker run -d \
        --name "${LOCALSTACK_CONTAINER}" \
        -p "${LOCALSTACK_PORT}:4566" \
        -e LOCALSTACK_AUTH_TOKEN="${LOCALSTACK_AUTH_TOKEN}" \
        "${LOCALSTACK_IMAGE}"
fi

# Wait for LocalStack Azure to be ready
info "Waiting for LocalStack Azure to be ready..."
elapsed=0
until curl -s "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    [ "${elapsed}" -lt 90 ] || {
        if [ -n "${LOCALSTACK_CONTAINER}" ]; then
            docker logs --tail 200 "${LOCALSTACK_CONTAINER}" || true
        fi
        die "LocalStack Azure did not become ready within 90s."
    }
done
success "LocalStack Azure is ready."

# Create Azure resources in LocalStack
info "Creating Azure resource group and Key Vault in LocalStack..."
azlocal_cmd group create \
    --name "${AZURE_RESOURCE_GROUP}" \
    --location "${AZURE_LOCATION}" >/dev/null

azlocal_cmd keyvault create \
    --name "${AZURE_VAULT_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --location "${AZURE_LOCATION}" >/dev/null

AZURE_VAULT_URL="$(azlocal_cmd keyvault show \
    --name "${AZURE_VAULT_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --query "properties.vaultUri" \
    -o tsv)"
[ -n "${AZURE_VAULT_URL}" ] || die "Failed to determine AZURE_VAULT_URL from LocalStack Key Vault."
success "Using Azure Key Vault URL: ${AZURE_VAULT_URL}"

# Write test secret
info "Writing test secret to Azure Key Vault..."
azlocal_cmd keyvault secret set \
    --vault-name "${AZURE_VAULT_NAME}" \
    --name "${AZURE_SECRET_NAME}" \
    --value "{\"${SECRET_FIELD}\":\"${SECRET_VALUE}\"}" >/dev/null
success "Secret written: ${AZURE_SECRET_NAME} ${SECRET_FIELD}=${SECRET_VALUE}"

# Build plugin
info "Building plugin and setting Azure Key Vault config..."
build_plugin
docker plugin disable "${PLUGIN_NAME}" --force 2>/dev/null || true
docker plugin set "${PLUGIN_NAME}" \
    SECRETS_PROVIDER="azure" \
    AZURE_VAULT_URL="${AZURE_VAULT_URL}" \
    AZURE_ACCESS_TOKEN="${PLUGIN_AZURE_ACCESS_TOKEN}" \
    ENABLE_ROTATION="true" \
    ROTATION_INTERVAL="10s" \
    ENABLE_MONITORING="false"
success "Plugin configured with Azure Key Vault settings."

# Enable plugin
info "Enabling plugin..."
enable_plugin

# Deploy stack
info "Deploying swarm stack..."
deploy_stack "${COMPOSE_FILE}" "${STACK_NAME}" 60

# Log service output
info "Logging service output..."
sleep 10
log_stack "${STACK_NAME}" "app"

# Compare password == logged secret
info "Verifying secret value matches expected password..."
verify_secret "${STACK_NAME}" "app" "${SECRET_NAME}" "${SECRET_VALUE}" 60

# Rotate and verify
info "Rotating secret in Azure Key Vault..."
azlocal_cmd keyvault secret set \
    --vault-name "${AZURE_VAULT_NAME}" \
    --name "${AZURE_SECRET_NAME}" \
    --value "{\"${SECRET_FIELD}\":\"${SECRET_VALUE_ROTATED}\"}" >/dev/null
success "Secret rotated to: ${SECRET_VALUE_ROTATED}"

info "Waiting for plugin rotation interval (30s)..."
sleep 30

info "Logging service output after rotation..."
log_stack "${STACK_NAME}" "app"

info "Verifying rotated secret value..."
verify_secret "${STACK_NAME}" "app" "${SECRET_NAME}" "${SECRET_VALUE_ROTATED}" 180

success "Azure Key Vault smoke test PASSED"
