// neo4j-with-storage-create.bicep (NO storage key stored/created by Bicep)

param location string
param environmentName string
param acrName string
param keyVaultName string
param userAssignedIdentityName string = 'salesopt-container-identity'

param neo4jAppName string = 'neo4j'
param imageRepo string = 'neo4j-custom'
param imageTag string = 'latest'

@description('Key Vault secret name whose VALUE is like "neo4j/YourStrongPassword"')
param neo4jAuthSecretName string = 'NEO4J-AUTH'

@description('If true, create a new Storage Account + File Share. NOTE: this template will NOT store its key anywhere.')
param createStorage bool = true

@description('Optional: If createStorage=false, provide an existing storage account name (lowercase, 3-24 chars).')
param storageAccountName string = ''

param fileShareName string = 'neo4jfiles'

@description('Key Vault secret name that ALREADY contains the Storage Account KEY (for Azure Files mount). This template will NOT create/update it.')
param storageKeySecretName string = 'NEO4J-STORAGE-KEY'

@description('If true, configure Managed Environment storage (Azure Files mount) + mount it in Neo4j container. Requires Key Vault secret to already exist.')
param configureEnvStorage bool = true

@description('Expose Bolt (7687) externally. External TCP ingress may require special env/network setup.')
param exposeBoltExternally bool = false

@description('If true, remove existing /data/dbms/auth* files at startup so NEO4J_AUTH can be reapplied. Use only when intentionally rotating/resetting credentials.')
param forceResetAuth bool = false

// -------------------------
// Existing resources
// -------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: userAssignedIdentityName
}

resource env 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: environmentName
}

// -------------------------
// Storage: create (or use existing)
// -------------------------
var generatedStorageName = toLower('st${uniqueString(resourceGroup().id, neo4jAppName)}')
var storageName = empty(storageAccountName) ? generatedStorageName : toLower(storageAccountName)

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = if (createStorage) {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true
  }
}

resource storageExisting 'Microsoft.Storage/storageAccounts@2023-01-01' existing = if (!createStorage) {
  name: storageName
}

// Create file share only when creating storage
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (createStorage) {
  name: '${storage.name}/default/${fileShareName}'
  properties: {
    shareQuota: 100
  }
}

// -------------------------
// Managed Environment Storage (Azure Files)
// NOTE: We DO NOT create/write the storage key secret here.
// It must already exist in Key Vault as: https://{vault}.vault.azure.net/secrets/{storageKeySecretName}
// -------------------------
resource envStorage 'Microsoft.App/managedEnvironments/storages@2025-07-01' = if (configureEnvStorage) {
  name: 'neo4jstorage'
  parent: env
  properties: {
    azureFile: {
      accountName: storageName
      shareName: fileShareName
      accessMode: 'ReadWrite'
      accountKeyVaultProperties: {
        identity: mi.id
        keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${storageKeySecretName}'
      }
    }
  }
  dependsOn: createStorage ? [
    fileShare
  ] : []
}

var fqdn = '${neo4jAppName}.${env.properties.defaultDomain}'
var boltAdvertisedAddress = exposeBoltExternally ? '${fqdn}:7687' : '${neo4jAppName}:7687'

// -------------------------
// Neo4j Container App
// -------------------------
resource neo4jApp 'Microsoft.App/containerApps@2025-10-02-preview' = {
  name: neo4jAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${mi.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 7474
        transport: 'auto'
        additionalPortMappings: exposeBoltExternally ? [
          {
            external: true
            targetPort: 7687
            exposedPort: 7687
          }
        ] : []
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: mi.id
        }
      ]
      secrets: [
        {
          name: 'neo4j-auth'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${neo4jAuthSecretName}'
          identity: mi.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'neo4j'
          image: '${acr.properties.loginServer}/${imageRepo}:${imageTag}'
          resources: { cpu: json('2.0'), memory: '4.0Gi' }

          env: [
            { name: 'NEO4J_AUTH', secretRef: 'neo4j-auth' }
            { name: 'NEO4J_server_default__listen__address', value: '0.0.0.0' }
            { name: 'NEO4J_server_default__advertised__address', value: fqdn }
            { name: 'NEO4J_server_bolt_listen__address', value: ':7687' }
            { name: 'NEO4J_server_bolt_advertised__address', value: boltAdvertisedAddress }
            { name: 'NEO4J_server_http_listen__address', value: ':7474' }
            { name: 'NEO4J_server_http_advertised__address', value: '${fqdn}:443' }
            { name: 'NEO4J_FORCE_RESET_AUTH', value: forceResetAuth ? 'true' : 'false' }

            // Keep everything under /data so it persists when mounted
            { name: 'NEO4J_server_directories_data', value: '/data' }
            { name: 'NEO4J_server_directories_logs', value: '/data/logs' }
            { name: 'NEO4J_server_directories_import', value: '/data/import' }
            { name: 'NEO4J_server_directories_plugins', value: '/data/plugins' }

            { name: 'NEO4J_dbms_security_allow__csv__import__from__file__urls', value: 'true' }
            { name: 'NEO4J_server_memory_heap_initial__size', value: '512m' }
            { name: 'NEO4J_server_memory_heap_max__size', value: '512m' }
          ]

          volumeMounts: configureEnvStorage ? [
            { volumeName: 'neo4jfiles', mountPath: '/data' }
          ] : []
        }
      ]

      volumes: configureEnvStorage ? [
        {
          name: 'neo4jfiles'
          storageType: 'AzureFile'
          storageName: 'neo4jstorage' // must match envStorage.name
          mountOptions: 'uid=7474,gid=7474,file_mode=0777,dir_mode=0777'
        }
      ] : []

      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: configureEnvStorage ? [
    envStorage
  ] : []
}

output neo4jBrowserUrl string = 'https://${fqdn}'
output storageAccountCreatedName string = storageName
output neo4jBoltUri string = exposeBoltExternally ? 'neo4j://${fqdn}:7687' : 'neo4j://${neo4jAppName}:7687'
