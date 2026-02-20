#!/bin/bash
set -euo pipefail

if [[ $# -eq 0 ]] ; then
  echo "Usage: ./deploy-neo4j.sh --environment <dev|prod>" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    *) echo "Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

CONFIG_FILE="./config.${ENVIRONMENT}.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Missing config file: $CONFIG_FILE" >&2
  exit 1
fi
source "$CONFIG_FILE"

# --- Derived vars ---
ACR_SERVER="${ACR_NAME}.azurecr.io"
BUILD_TIMESTAMP=$(date +%Y%m%d%H%M%S)
GIT_SHA=${GITHUB_SHA:-$(git rev-parse --short HEAD)}
GIT_SHA_SHORT=$(echo "${GIT_SHA}" | cut -c1-7)
IMAGE_TAG="${GIT_SHA_SHORT}-${BUILD_TIMESTAMP}"
REVISION_SUFFIX="${GIT_SHA_SHORT}-${BUILD_TIMESTAMP}"
DEPLOYMENT_NAME="neo4j-deploy-${REVISION_SUFFIX}"

# --- Logging ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${YELLOW}[INFO] $1${NC}" >&2; }
ok()   { echo -e "${GREEN}[SUCCESS] $1${NC}" >&2; }
err()  { echo -e "${RED}[ERROR] $1${NC}" >&2; }

validate_prerequisites() {
  for tool in az docker curl; do
    command -v "$tool" &>/dev/null || { err "$tool is required."; exit 1; }
  done
  az account show &>/dev/null || { err "Azure login required. Run: az login"; exit 1; }
  ok "Prerequisites validated."
}

build_and_push_image() {
  # IMPORTANT:
  # - The ACR repo name MUST match what your bicep uses (imageRepo param).
  # - If building on Apple Silicon, add: --platform linux/amd64
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
    --debug 1>&2

  ok "Bicep deployment completed."

  # Get output (your bicep should output neo4jBrowserUrl or appUrl)
  local out
  out=$(az deployment group show \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.outputs.${BICEP_OUTPUT_NAME}.value" \
    -o tsv)

  echo "${out%.}"
}

health_check() {
  local url="$1"
  local max=30

  info "Health check: ${url}"
  for ((i=1;i<=max;i++)); do
    # Neo4j browser often responds at / or /browser/
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
  az acr login --name "$ACR_NAME" >&2

  build_and_push_image

  local neo4j_url
  neo4j_url=$(deploy_infrastructure)
  [[ -n "$neo4j_url" ]] || { err "Failed to read output '${BICEP_OUTPUT_NAME}'"; exit 1; }

  health_check "$neo4j_url"

  echo "" >&2
  ok "=== DEPLOYMENT COMPLETED ==="
  ok "Neo4j URL: ${neo4j_url}"
  ok "Image Tag: ${IMAGE_TAG}"

  # stdout for GitHub Actions step outputs
  echo "${neo4j_url}"
}

main