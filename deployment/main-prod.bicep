// neo4j-with-storage-create.bicep

param location string
param environmentName string
param acrName string
param keyVaultName string
param userAssignedIdentityName string = 'salesopt-container-identity'

param neo4jAppName string = 'neo4j'
param imageRepo string = 'neo4j-custom'
param imageTag string = 'latest'

param neo4jAuthSecretName string = 'NEO4J-AUTH'

param createStorage bool = true
param storageAccountName string = ''
param fileShareName string = 'neo4jfiles'
param createStorageKeySecret bool = true

@description('Key Vault secret name containing the Storage Account KEY (for Azure Files mount)')
param storageKeySecretName string = 'NEO4J-STORAGE-KEY'

// Networking
@description('Expose Bolt (7687) externally. External additional TCP ports often require VNET-injected Container Apps env.')
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

var generatedStorageName = toLower('st${substring(uniqueString(resourceGroup().id, neo4jAppName), 0, 18)}')
var storageName = empty(storageAccountName) ? generatedStorageName : toLower(storageAccountName)

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = if (createStorage) {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true
  }
}

resource storageExisting 'Microsoft.Storage/storageAccounts@2023-01-01' existing = if (!createStorage) {
  name: storageName
}

var storageId = createStorage ? storage.id : storageExisting.id
var storageKey = createStorage ? storage.listKeys().keys[0].value : ''  // only used if createStorage=true

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (createStorage) {
  name: '${storage.name}/default/${fileShareName}'
  properties: {
    shareQuota: 100
  }
  dependsOn: [
    storage
  ]
}

resource fileShareExisting 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' existing = if (!createStorage) {
  name: '${storageExisting.name}/default/${fileShareName}'
}


resource storageKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = if (createStorage && createStorageKeySecret) {
  name: '${keyVault.name}/${storageKeySecretName}'
  properties: {
    value: storageKey
  }
  dependsOn: [
    storage
  ]
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: '${env.name}/neo4jstorage'
  properties: {
    azureFile: {
      accountName: storageName
      shareName: fileShareName
      accountKeyVaultProperties: {
        identity: mi.id
        keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${storageKeySecretName}'
      }
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [
    fileShare
    storageKeySecret
  ]
}


var fqdn = '${neo4jAppName}.${env.properties.defaultDomain}'

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
        additionalPortMappings: [
          {
            external: exposeBoltExternally
            targetPort: 7687
            exposedPort: 7687
          }
        ]
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
          resources: {
            cpu: json('2.0')
            memory: '4.0Gi'
          }
          env: [
            { name: 'NEO4J_AUTH', secretRef: 'neo4j-auth' }
            { name: 'NEO4J_server_default__listen__address', value: '0.0.0.0' }
            { name: 'NEO4J_server_http_advertised__address', value: '${fqdn}:7474' }
            { name: 'NEO4J_server_bolt_advertised__address', value: '${fqdn}:7687' }
            { name: 'NEO4J_server_directories_data', value: '/data' }
            { name: 'NEO4J_server_directories_import', value: '/data/import' }
            { name: 'NEO4J_dbms_security_allow__csv__import__from__file__urls', value: 'true' }
            { name: 'NEO4J_server_memory_heap_initial__size', value: '512m' }
            { name: 'NEO4J_server_memory_heap_max__size', value: '512m' }
          ]
          volumeMounts: [
            {
              volumeName: 'neo4jfiles'
              mountPath: '/data'
            }
          ]
        }
      ]

      volumes: [
        {
          name: 'neo4jfiles'
          storageType: 'AzureFile'
          storageName: 'neo4jstorage'
          mountOptions: 'uid=7474,gid=7474,file_mode=0777,dir_mode=0777'
        }
      ]

      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    envStorage
  ]
}


output storageAccountCreatedName string = storageName
output neo4jBrowserUrl string = 'https://${fqdn}'
output neo4jBoltUri string = exposeBoltExternally ? 'neo4j://${fqdn}:7687' : 'neo4j://${neo4jAppName}:7687'
