#!/bin/bash

# Development Environment Configuration
ENVIRONMENT_NAME="Development"
RESOURCE_GROUP="testing-containers"
ACR_NAME="salesopttest"
LOCATION="canadacentral"
BICEP_FILE="./activepieces.bicep"
KEY_VAULT_NAME="salesopt-kv-test"
JWT_SECRET="60101f484c388ae3c862afee41f7da3f2ce03548d4caebe4f7f85ee34e7c99a6"
ENCRYPTION_KEY="04c7c35b3e32cb7b2353d758437a2bbe"
API_KEY="f379cfbee75176ebfe6f39b4b7dedf123b8cd54b8b5343180ee650625d5100532c5a9a954a0d98fc9079b31445ced0f1a24088d81ca30fd6e9951f8cc4701622"
UNIQUE_ID=$(head -c 4 /dev/urandom | xxd -p)

# App-specific name for the Activepieces container
APP_NAME_ACTIVEPIECES="agentops-dev"
# Names for your new Postgres and Redis resources
POSTGRES_SERVER_NAME="salesopt-pg-server-dev-b7e59be4"
POSTGRES_ADMIN_USER="salesoptadmin"
REDIS_CACHE_NAME="salesopt-redis-cache-dev-b7e59be4"
SALESOPTAI_APIS="https://portal.salesoptai.com , https://portal.nexopta.com , https://portal.nexopta.ai , https://gentle-grass-02d3f240f.1.azurestaticapps.net , https://salesopt-app.redriver-d84691b9.eastus.azurecontainerapps.io,  https://portal.salesopt.ai , https://salesoptai-app-prod.icystone-9246cdc7.canadaeast.azurecontainerapps.io"
# POSTGRES_SERVER_NAME="salesopt-pg-server-dev-3fae475d"
# POSTGRES_ADMIN_USER="salesoptadmin"
# REDIS_CACHE_NAME="salesopt-redis-cache-dev-3fae475d"
# SALESOPTAI_APIS="https://gentle-grass-02d3f240f.1.azurestaticapps.net"

#make sure we don't deploy any new infrastructure.
DEPLOY_NEW_INFRA='false'
