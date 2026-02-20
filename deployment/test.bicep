// Azure Container Apps deployment using Bicep (with optional Postgres/Redis provisioning)
param location string = resourceGroup().location
param environmentName string = 'testAPContainerEnvironment'
param keyVaultName string = 'salesopt-kv-test'
param acrName string = 'salesopttest'
param appImageTag string = 'latest'
param revisionSuffix string = ''
param frontendUrl string = 'https://portal.salesoptai.com/activepieces'

// ===== NEW: Toggles to create backing services when needed =====
@description('Create a new Azure Database for PostgreSQL Flexible Server?')
param createPostgres bool = true

@description('Create a new Azure Cache for Redis?')
param createRedis bool = true

// ===== NEW: Postgres inputs (used only if createPostgres = true) =====
@description('Name for the PostgreSQL Flexible Server (must be globally unique)')
param postgresServerName string = 'salesopt-pg-flex'

@description('Name of the initial database to create')
param postgresDbName string = 'activepieces'

@description('Key Vault secret name that stores the Postgres admin username')
param postgresAdminUserSecretName string = 'POSTGRES-ADMIN-USER'

@description('Key Vault secret name that stores the Postgres admin password')
param postgresAdminPasswordSecretName string = 'POSTGRES-ADMIN-PASSWORD'

// ===== NEW: Redis inputs (used only if createRedis = true) =====
@description('Name for Azure Cache for Redis instance')
param redisName string = 'salesopt-redis'

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param redisSkuName string = 'Standard'

@allowed(['C']) // family C for Basic/Standard/Premium (for classic redis)
param redisSkuFamily string = 'C'

@minValue(0)
@maxValue(6)
param redisSkuCapacity int = 1 // 0..6 maps to sizes; 1 ~ 1GB for Standard

// ===== EXISTING resources =====
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' existing = {
  name: acrName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource environment 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: environmentName
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'salesopt-container-identity'
}

// ===== Helper: read admin creds from Key Vault (for Postgres) =====
var pgAdminUser = listSecret('${keyVault.id}/secrets/${postgresAdminUserSecretName}', '2019-09-01').value
var pgAdminPass = listSecret('${keyVault.id}/secrets/${postgresAdminPasswordSecretName}', '2019-09-01').value

// ===== POSTGRES FLEXIBLE SERVER (optional) =====
resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01' = if (createPostgres) {
  name: postgresServerName
  location: location
  sku: {
    name: 'Standard_D2ds_v4' // pick size to taste
    tier: 'GeneralPurpose'
    capacity: 2
  }
  properties: {
    version: '16'
    administratorLogin: pgAdminUser
    administratorLoginPassword: pgAdminPass
    availabilityZone: '1'
    network: {
      publicNetworkAccess: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    storage: {
      storageSizeGB: 64
      autoGrow: 'Enabled'
      iops: 300
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
      tenantId: ''
    }
  }
}

// Create the initial DB (optional but handy)
resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01' = if (createPostgres) {
  name: '${pgServer.name}/${postgresDbName}'
  properties: {}
}

// Compute Postgres host and full connection string
var pgHost = createPostgres ? '${postgresServerName}.postgres.database.azure.com' : '' // when not creating, you might set this via a param instead

// Connection string encoded password (URI-safe)
var pgConnString = createPostgres
  ? 'postgres://${pgAdminUser}:${uriComponent(pgAdminPass)}@${pgHost}:5432/${postgresDbName}?sslmode=require'
  : ''

// ===== REDIS (optional) =====
resource redis 'Microsoft.Cache/redis@2023-04-01' = if (createRedis) {
  name: redisName
  location: location
  sku: {
    name: redisSkuName
    family: redisSkuFamily
    capacity: redisSkuCapacity
  }
  properties: {
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    redisConfiguration: {}
  }
}

// Grab redis hostname and key for the connection string
var redisHost = createRedis ? reference(resourceId('Microsoft.Cache/redis', redisName), '2023-04-01').hostName : ''
var redisKeys = createRedis ? listKeys(resourceId('Microsoft.Cache/redis', redisName), '2023-04-01') : {}
var redisPrimaryKey = createRedis ? redisKeys.primaryKey : ''
var redisConnString = createRedis ? 'rediss://:${redisPrimaryKey}@${redisHost}:6380' : ''

// ===== Write/Update connection strings back to Key Vault secrets =====
// These secret names match what your app expects in the Container App config below.
resource kvSecretPostgresUrl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (createPostgres) {
  name: '${keyVault.name}/POSTGRES-DATABASE-URL'
  properties: {
    value: pgConnString
  }
}

resource kvSecretRedisUrl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (createRedis) {
  name: '${keyVault.name}/REDIS-URL'
  properties: {
    value: redisConnString
  }
}

// ===== CONTAINER APP (external) =====
resource activiepiecesApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'activiepiecesApp'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        corsPolicy: {
          allowedOrigins: [
            'https://portal.salesoptai.com'
            'http://localhost:8080'
          ]
          allowedMethods: [
            'GET'
            'POST'
            'PUT'
            'DELETE'
            'OPTIONS'
          ]
          allowedHeaders: ['*']
          allowCredentials: true
        }
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: managedIdentity.id
        }
      ]
      // The app will read these secrets at runtime via managed identity
      secrets: [
        {
          name: 'postgres-database-url'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/POSTGRES-DATABASE-URL'
          identity: managedIdentity.id
        }
        {
          name: 'redis-url'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/REDIS-URL'
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      revisionSuffix: revisionSuffix
      containers: [
        {
          image: '${acr.properties.loginServer}/salesopt-activepieces-app:${appImageTag}'
          name: 'activiepieces-app'
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          env: [
            { name: 'AP_ENVIRONMENT', value: 'prod' }
            { name: 'AP_FRONTEND_URL', value: frontendUrl }
            { name: 'AP_EXECUTION_MODE', value: 'UNSANDBOXED' }

            { name: 'AP_DB_TYPE', value: 'POSTGRES' }
            { name: 'AP_POSTGRES_URL', secretRef: 'postgres-database-url' }

            { name: 'AP_QUEUE_MODE', value: 'REDIS' }
            { name: 'AP_REDIS_URL', secretRef: 'redis-url' }

            { name: 'AP_WEBHOOK_TIMEOUT_SECONDS', value: '30' }
            { name: 'AP_TRIGGER_DEFAULT_POLL_INTERVAL', value: '5' }
            { name: 'AP_FLOW_TIMEOUT_SECONDS', value: '600' }
            { name: 'AP_TELEMETRY_ENABLED', value: 'true' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 5
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '100'
              }
            }
          }
        ]
      }
    }
  }
}

// Outputs
output appUrl string = activiepiecesApp.properties.configuration.ingress.fqdn
