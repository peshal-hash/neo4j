#!/bin/bash

ENVIRONMENT_NAME="testAPContainerEnvironment"
RESOURCE_GROUP="testing-containers"
ACR_NAME="salesopttest"
LOCATION="canadacentral"
BICEP_FILE="./main-prod.bicep"
KEY_VAULT_NAME="salesopt-kv-test"
UNIQUE_ID=$(head -c 4 /dev/urandom | xxd -p)

BICEP_FILE="./main-prod.bicep"
BICEP_OUTPUT_NAME="neo4jBrowserUrl"   # or "appUrl" depending on your bicep outputs

NEO4J_APP_NAME="neo4j-prod"
NEO4J_IMAGE_REPO="neo4j-custom"
NEO4J_DOCKERFILE="../Dockerfile"
NEO4J_CONTEXT=".."

NEO4J_AUTH_SECRET_NAME="NEO4J-AUTH"
STORAGE_KEY_SECRET_NAME="NEO4J-STORAGE-KEY"  # value is storage account key

CREATE_STORAGE="true"                    # Create new storage account
CONFIGURE_ENV_STORAGE="true"             # Configure Azure Files mount
STORAGE_ACCOUNT_NAME=""                  # Empty = let Bicep generate unique name
FILE_SHARE_NAME="neo4jfiles"

# Networking
EXPOSE_BOLT_EXTERNALLY="false"

# Auth lifecycle
# Keep "false" for normal deploys; set "true" only when you intentionally want
# to clear current Neo4j auth state and reapply NEO4J_AUTH from Key Vault.
FORCE_RESET_AUTH="true"  # TEMPORARY: revert to "false" after one successful deploy
