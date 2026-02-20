// neo4j-with-storage-create.bicep

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

param createStorage bool = true
@description('Optional: If createStorage=false, provide an existing storage account name (lowercase, 3-24 chars).')
param storageAccountName string = ''
param fileShareName string = 'neo4jfiles'

@description('Key Vault secret name containing the Storage Account KEY (for Azure Files mount)')
param storageKeySecretName string = 'NEO4J-STORAGE-KEY'

@description('Expose Bolt (7687) externally. External TCP ingress may require special env/network setup.')
param exposeBoltExternally bool = false

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
// FIX: uniqueString is 13 chars; do NOT substring to 18.
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

// Read key only when creating storage
var storageKey = createStorage ? storage.listKeys().keys[0].value : ''

// Store the storage key in Key Vault when we created it
resource storageKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = if (createStorage) {
  name: '${keyVault.name}/${storageKeySecretName}'
  properties: {
    value: storageKey
  }
}

// -------------------------
// Managed Environment Storage (Azure Files)
// IMPORTANT: Use API that supports accountKeyVaultProperties
// -------------------------
resource envStorage 'Microsoft.App/managedEnvironments/storages@2025-07-01' = {
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
    storageKeySecret
  ] : []
}

var fqdn = '${neo4jAppName}.${env.properties.defaultDomain}'

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

          // Single mount at /data, then keep everything inside /data/* so it persists.
          env: [
            { name: 'NEO4J_AUTH', secretRef: 'neo4j-auth' }

            { name: 'NEO4J_server_default__listen__address', value: '0.0.0.0' }

            { name: 'NEO4J_server_directories_data', value: '/data' }
            { name: 'NEO4J_server_directories_logs', value: '/data/logs' }
            { name: 'NEO4J_server_directories_import', value: '/data/import' }
            { name: 'NEO4J_server_directories_plugins', value: '/data/plugins' }

            { name: 'NEO4J_dbms_security_allow__csv__import__from__file__urls', value: 'true' }
            { name: 'NEO4J_server_memory_heap_initial__size', value: '512m' }
            { name: 'NEO4J_server_memory_heap_max__size', value: '512m' }
          ]

          volumeMounts: [
            { volumeName: 'neo4jfiles', mountPath: '/data' }
          ]
        }
      ]

      volumes: [
        {
          name: 'neo4jfiles'
          storageType: 'AzureFile'
          // FIX: must be the ENV storage resource name, not storage account name
          storageName: 'neo4jstorage'
          mountOptions: 'uid=7474,gid=7474,file_mode=0777,dir_mode=0777'
        }
      ]

      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [
    envStorage
  ]
}

output neo4jBrowserUrl string = 'https://${fqdn}'
output storageAccountCreatedName string = storageName
output neo4jBoltUri string = exposeBoltExternally ? 'neo4j://${fqdn}:7687' : 'neo4j://${neo4jAppName}:7687'
