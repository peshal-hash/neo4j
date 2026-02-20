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
  echo "Usage: ./deploy-neo4j.sh --environment <dev|prod>" >&2
}

# -------------------------
# Args
# -------------------------
if [[ $# -eq 0 ]] ; then
  usage
  exit 1
fi

ENVIRONMENT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --environment) ENVIRONMENT="$2"; shift 2 ;;
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

  echo "${out%.}"
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

main() {
  ok "Starting Neo4j deployment: ${ENVIRONMENT_NAME}"
  info "Deployment ID: ${REVISION_SUFFIX}"

  validate_prerequisites

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

  echo "" >&2
  ok "=== DEPLOYMENT COMPLETED ==="
  ok "Neo4j URL: ${neo4j_url}"
  ok "Image Tag: ${IMAGE_TAG}"

  echo "${neo4j_url}"
}

main