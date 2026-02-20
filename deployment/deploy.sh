#!/bin/bash
set -Eeuo pipefail

# -------------------------
# Logging + error handler
# -------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${YELLOW}[INFO] $1${NC}" >&2; }
ok()   { echo -e "${GREEN}[SUCCESS] $1${NC}" >&2; }
err()  { echo -e "${RED}[ERROR] $1${NC}" >&2; }

# Where we store the last AZ error output
AZ_ERR_LOG="/tmp/neo4j_az_err_${RANDOM}.log"
NEO4J_BOLT_URI=""

print_last_az_error() {
  if [[ -s "${AZ_ERR_LOG}" ]]; then
    err "Azure CLI error output (last command):"
    echo "------------------------------------------------------------" >&2
    cat "${AZ_ERR_LOG}" >&2
    echo "------------------------------------------------------------" >&2
  fi
}

print_deployment_failure_details() {
  # Best-effort: if the deployment exists, show details. If not, just return.
  az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    -o jsonc 1>/dev/null 2>&1 || return 0

  err "Azure deployment exists. Fetching failure details..."
  az deployment group show \
    --name "${DEPLOYMENT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "{state:properties.provisioningState, error:properties.error}" \
    -o jsonc >&2 || true
}

on_error() {
  local exit_code=$?
  err "Script failed (exit=${exit_code}) at line ${BASH_LINENO[0]}."
  err "Command: ${BASH_COMMAND}"
  print_last_az_error
  print_deployment_failure_details
  exit "${exit_code}"
}
trap on_error ERR

usage() {
  echo "Usage: ./deploy-neo4j.sh --environment <dev|prod> [--force-reset-auth <true|false>]" >&2
}

# -------------------------
# Args
# -------------------------
if [[ $# -eq 0 ]] ; then
  usage
  exit 1
fi

ENVIRONMENT=""
FORCE_RESET_AUTH_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --force-reset-auth) FORCE_RESET_AUTH_OVERRIDE="$2"; shift 2 ;;
    *) echo "Unknown parameter: $1" >&2; usage; exit 1 ;;
  esac
done

CONFIG_FILE="./config.${ENVIRONMENT}.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
  err "Missing config file: $CONFIG_FILE"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -n "${FORCE_RESET_AUTH_OVERRIDE}" ]]; then
  case "${FORCE_RESET_AUTH_OVERRIDE,,}" in
    true|false) FORCE_RESET_AUTH="${FORCE_RESET_AUTH_OVERRIDE,,}" ;;
    *)
      err "Invalid value for --force-reset-auth. Use 'true' or 'false'."
      exit 1
      ;;
  esac
fi

# -------------------------
# Derived vars
# -------------------------
ACR_SERVER="${ACR_NAME}.azurecr.io"
BUILD_TIMESTAMP=$(date +%Y%m%d%H%M%S)
GIT_SHA=${GITHUB_SHA:-$(git rev-parse --short HEAD)}
GIT_SHA_SHORT=$(echo "${GIT_SHA}" | cut -c1-7)
IMAGE_TAG="${GIT_SHA_SHORT}-${BUILD_TIMESTAMP}"
REVISION_SUFFIX="${GIT_SHA_SHORT}-${BUILD_TIMESTAMP}"
DEPLOYMENT_NAME="neo4j-deploy-${REVISION_SUFFIX}"

validate_prerequisites() {
  for tool in az docker curl; do
    command -v "$tool" &>/dev/null || { err "$tool is required."; exit 1; }
  done
  az account show &>/dev/null || { err "Azure login required. Run: az login"; exit 1; }
  ok "Prerequisites validated."
}

validate_neo4j_auth_secret() {
  info "Validating Key Vault secret '${NEO4J_AUTH_SECRET_NAME}' format..."
  : > "${AZ_ERR_LOG}"

  local auth_value
  auth_value="$(az keyvault secret show \
    --vault-name "${KEY_VAULT_NAME}" \
    --name "${NEO4J_AUTH_SECRET_NAME}" \
    --query value \
    -o tsv 2> >(tee "${AZ_ERR_LOG}" >&2))"

  [[ -n "${auth_value}" ]] || {
    err "Key Vault secret '${NEO4J_AUTH_SECRET_NAME}' is empty."
    exit 1
  }

  if [[ "${auth_value}" == "none" ]]; then
    err "Key Vault secret '${NEO4J_AUTH_SECRET_NAME}' is set to 'none'. Auth is disabled."
    exit 1
  fi

  if [[ "${auth_value}" != neo4j/* ]]; then
    err "Key Vault secret '${NEO4J_AUTH_SECRET_NAME}' must be formatted as 'neo4j/<password>'."
    exit 1
  fi

  local password_part="${auth_value#neo4j/}"
  [[ -n "${password_part}" ]] || {
    err "Key Vault secret '${NEO4J_AUTH_SECRET_NAME}' has no password after 'neo4j/'."
    exit 1
  }

  ok "Auth secret format is valid (user=neo4j)."
}

build_and_push_image() {
  info "Building image: ${ACR_SERVER}/${NEO4J_IMAGE_REPO}:${IMAGE_TAG}"
  docker build \
    -t "${ACR_SERVER}/${NEO4J_IMAGE_REPO}:${IMAGE_TAG}" \
    -f "${NEO4J_DOCKERFILE}" \
    "${NEO4J_CONTEXT}" >&2

  info "Pushing image..."
  docker push "${ACR_SERVER}/${NEO4J_IMAGE_REPO}:${IMAGE_TAG}" >&2
  ok "Image pushed: ${ACR_SERVER}/${NEO4J_IMAGE_REPO}:${IMAGE_TAG}"
}

deploy_infrastructure() {
  info "Deploying Bicep to RG=${RESOURCE_GROUP} (env=${ENVIRONMENT_NAME})..."
  : > "${AZ_ERR_LOG}"

  # Use --only-show-errors to reduce noise; keep stderr in a log we can print on failure.
  # If you still want full debug, set AZ_DEBUG=1 in environment and we'll add --debug.
  local debug_flag=()
  if [[ "${AZ_DEBUG:-0}" == "1" ]]; then
    debug_flag=(--debug)
  else
    debug_flag=(--only-show-errors)
  fi

  az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$BICEP_FILE" \
    --parameters \
      location="$LOCATION" \
      environmentName="$ENVIRONMENT_NAME" \
      acrName="$ACR_NAME" \
      keyVaultName="$KEY_VAULT_NAME" \
      neo4jAppName="$NEO4J_APP_NAME" \
      imageRepo="$NEO4J_IMAGE_REPO" \
      imageTag="$IMAGE_TAG" \
      neo4jAuthSecretName="$NEO4J_AUTH_SECRET_NAME" \
      storageAccountName="$STORAGE_ACCOUNT_NAME" \
      fileShareName="$FILE_SHARE_NAME" \
      storageKeySecretName="$STORAGE_KEY_SECRET_NAME" \
      exposeBoltExternally="$EXPOSE_BOLT_EXTERNALLY" \
      forceResetAuth="${FORCE_RESET_AUTH:-false}" \
      configureEnvStorage="${CONFIGURE_ENV_STORAGE:-true}" \
      createStorage="${CREATE_STORAGE:-false}" \
    "${debug_flag[@]}" \
    2> >(tee "${AZ_ERR_LOG}" >&2)

  ok "Bicep deployment completed."

  local out
  out=$(az deployment group show \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.outputs.${BICEP_OUTPUT_NAME}.value" \
    -o tsv 2> >(tee "${AZ_ERR_LOG}" >&2))

  NEO4J_BOLT_URI="$(az deployment group show \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.outputs.neo4jBoltUri.value" \
    -o tsv 2> >(tee "${AZ_ERR_LOG}" >&2) || true)"

  echo "${out%.}"
}

extract_host_from_url() {
  local url="$1"
  local host="${url#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  echo "${host}"
}

health_check() {
  local url="$1"
  local max=30

  info "Health check: ${url}"
  for ((i=1;i<=max;i++)); do
    if curl -fsSL --max-time 5 -o /dev/null "${url}/" \
      || curl -fsSL --max-time 5 -o /dev/null "${url}/browser/"; then
      ok "Health check passed on attempt $i."
      return 0
    fi
    info "Attempt $i/$max failed, retrying in 10s..."
    sleep 10
  done

  info "Health check did not pass after $max attempts; continuing."
  return 0
}

validate_ingress_configuration() {
  : > "${AZ_ERR_LOG}"
  info "Validating Azure Container App ingress for ${NEO4J_APP_NAME}..."

  local target_port
  target_port="$(az containerapp show \
    --name "${NEO4J_APP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "properties.configuration.ingress.targetPort" \
    -o tsv 2> >(tee "${AZ_ERR_LOG}" >&2))"
  [[ "${target_port}" == "7474" ]] || {
    err "Container App ingress targetPort is '${target_port}', expected '7474'."
    exit 1
  }

  local additional_ports
  additional_ports="$(az containerapp show \
    --name "${NEO4J_APP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "properties.configuration.ingress.additionalPortMappings" \
    -o json 2> >(tee "${AZ_ERR_LOG}" >&2))"

  if [[ "${EXPOSE_BOLT_EXTERNALLY,,}" == "true" ]]; then
    if [[ "${additional_ports}" != *'"exposedPort": 7687'* || "${additional_ports}" != *'"targetPort": 7687'* ]]; then
      err "Bolt external port mapping (7687) is missing from Container App ingress."
      exit 1
    fi
  fi

  ok "Container App ingress configuration validated."
}

validate_discovery_metadata() {
  local url="$1"
  local expected_host
  expected_host="$(extract_host_from_url "${url}")"
  info "Validating Neo4j discovery metadata from ${url}/ ..."

  local payload
  payload="$(curl -fsSL --max-time 10 -H "Accept: application/json" "${url}/")"

  local compact_payload
  compact_payload="$(printf '%s' "${payload}" | tr -d '\n')"

  local bolt_routing
  bolt_routing="$(printf '%s' "${compact_payload}" | sed -nE 's/.*"bolt_routing"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
  local bolt_direct
  bolt_direct="$(printf '%s' "${compact_payload}" | sed -nE 's/.*"bolt_direct"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"

  [[ -n "${bolt_routing}" || -n "${bolt_direct}" ]] || {
    err "Neo4j discovery payload is missing bolt metadata. Check if Neo4j HTTP endpoint is healthy."
    exit 1
  }

  local advertised="${bolt_routing:-${bolt_direct}}"
  if [[ "${advertised}" == *"localhost"* || "${advertised}" == *"127.0.0.1"* ]]; then
    err "Neo4j is advertising '${advertised}'. This breaks remote Browser/driver discovery."
    exit 1
  fi

  if [[ "${advertised}" != *"${expected_host}"* ]]; then
    info "Advertised bolt endpoint '${advertised}' does not include expected host '${expected_host}'."
  fi

  ok "Discovery metadata validated (advertised=${advertised})."
}

check_bolt_port_reachability() {
  local url="$1"
  local host
  host="$(extract_host_from_url "${url}")"
  info "Checking TCP reachability for ${host}:7687 ..."

  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/7687" 2>/dev/null; then
    ok "Bolt port 7687 is reachable."
    return 0
  fi

  err "Bolt port 7687 is not reachable on ${host}. Browser discovery will fail."
  return 1
}

main() {
  ok "Starting Neo4j deployment: ${ENVIRONMENT_NAME}"
  info "Deployment ID: ${REVISION_SUFFIX}"

  validate_prerequisites
  validate_neo4j_auth_secret

  info "ACR login: ${ACR_NAME}"
  : > "${AZ_ERR_LOG}"
  az acr login --name "$ACR_NAME" 2> >(tee "${AZ_ERR_LOG}" >&2)

  build_and_push_image

  local neo4j_url=""
  # IMPORTANT: do NOT use neo4j_url=$(...) without checking status.
  if ! neo4j_url="$(deploy_infrastructure)"; then
    err "Infrastructure deployment failed."
    exit 1
  fi

  [[ -n "$neo4j_url" ]] || { err "Failed to read output '${BICEP_OUTPUT_NAME}'"; exit 1; }

  health_check "$neo4j_url"
  validate_ingress_configuration
  validate_discovery_metadata "$neo4j_url"
  check_bolt_port_reachability "$neo4j_url"

  echo "" >&2
  ok "=== DEPLOYMENT COMPLETED ==="
  ok "Neo4j URL: ${neo4j_url}"
  [[ -n "${NEO4J_BOLT_URI}" ]] && ok "Neo4j Bolt URI: ${NEO4J_BOLT_URI}"
  ok "Image Tag: ${IMAGE_TAG}"

  echo "${neo4j_url}"
}

main
