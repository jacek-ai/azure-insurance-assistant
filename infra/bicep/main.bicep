@description('ObjectId logged in user (Entra ID)')
param userObjectId string

@allowed([
  'User'
  'ServicePrincipal'
])
@description('Principal type for userObjectId. Use User for interactive deployments, ServicePrincipal for CI/OIDC.')
param userPrincipalType string = 'User'

@secure()
@description('Azure Functions host key value to store in the AI Foundry Project connection as x-functions-key. Leave empty to skip creating the connection.')
param functionXFunctionsKey string = ''

@description('AI Foundry Project connection name for the Azure Functions x-functions-key')
param functionProjectConnectionName string = 'con-function-insurance-assistance'

@description('Whether to create a Key Vault and store the Functions host key as a secret')
param createKeyVault bool = false

@description('Key Vault name (used only when createKeyVault=true)')
param keyVaultName string = ''

@description('Key Vault secret name to store the Functions host key (used only when createKeyVault=true)')
param keyVaultFunctionKeySecretName string = 'functions-host-key-default'

@description('Location of all resources')
param location string = resourceGroup().location

@allowed([
  'Enabled'
  'Disabled'
])
@description('Public network access setting for the AI Foundry account. Some tenants/policies require this to be set explicitly.')
param aiFoundryPublicNetworkAccess string = 'Enabled'

@description('Azure AI Search index name used by the Functions tool (RAG retrieval)')
param searchIndexName string = 'knowledgesource-index'

@description('Blob container name holding the product catalog JSON')
param productsContainerName string = 'products'

@description('Blob name of the product catalog JSON')
param productsBlobName string = 'products.json'

// Resource names
var searchName = 'insast-dev-swedencen-srch-0001'
var aiFoundryName = 'insast-dev-swedencen-ai-0001'
var aiProjectName = 'insast-dev-swedencen-proj-0001'
var saName = 'insastdevswedencen0001'
var functionAppName = 'insast-dev-swedencen-fapp-0001'

/*
  An AI Foundry resources
*/
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: aiFoundryName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  properties: {
    // required to work in AI Foundry
    allowProjectManagement: true

    // Defines developer API endpoint subdomain
    customSubDomainName: aiFoundryName

    // Explicitly set to avoid BadRequest on updates in some environments.
    publicNetworkAccess: aiFoundryPublicNetworkAccess

    disableLocalAuth: true
  }
}

/*
  Foundry project
*/
resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  name: aiProjectName
  parent: aiFoundry
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

/*
  Foundry models deployment
*/
module models 'modules/models.bicep' = {
  name: 'models'
  params: {
    foundryName: aiFoundry.name
  }
  dependsOn: [
    aiProject
  ]
}

/* 
  Azure AI Search deployment
*/
resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'free'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

// Standard public cloud endpoint for Azure AI Search
var searchServiceEndpoint = 'https://${searchService.name}.search.windows.net'

/*
  Storage module deployment
*/
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: saName
    containerNameRagData: 'rag-data'
    containerNameProducts: 'products'
  }
}

/*
  Azure Functions (Consumption)
*/
module functionApp 'modules/functionapp.bicep' = {
  name: 'functionApp'
  params: {
    location: location
    functionAppName: functionAppName
    storageAccountName: saName
    searchServiceEndpoint: searchServiceEndpoint
    searchIndexName: searchIndexName
    productsContainerName: productsContainerName
    productsBlobName: productsBlobName
  }
  dependsOn: [
    storage
  ]
}

// Used to set the Function App host key within the same deployment (so one secret works end-to-end).
resource functionKeySetterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${functionAppName}-keysetter'
  location: location
}

resource setFunctionHostKey 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (!empty(functionXFunctionsKey)) {
  name: '${functionAppName}-set-hostkey'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${functionKeySetterIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.55.0'
    retentionInterval: 'P1D'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    forceUpdateTag: uniqueString(functionXFunctionsKey)
    environmentVariables: [
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroup().name
      }
      {
        name: 'FUNCTION_APP_NAME'
        value: functionAppName
      }
      {
        name: 'FUNCTION_X_FUNCTIONS_KEY'
        secureValue: functionXFunctionsKey
      }
    ]
    scriptContent: '''
set -euo pipefail

echo "Setting Function App host key 'default'..."
az functionapp keys set \
  -g "$RESOURCE_GROUP" \
  -n "$FUNCTION_APP_NAME" \
  --key-type functionKeys \
  --key-name default \
  --key-value "$FUNCTION_X_FUNCTIONS_KEY" \
  -o none
echo "Done."
'''
  }
  dependsOn: [
    functionApp
    rbac
  ]
}

module keyVault 'modules/keyvault.bicep' = if (createKeyVault && !empty(keyVaultName) && !empty(functionXFunctionsKey)) {
  name: 'keyVault'
  params: {
    location: location
    keyVaultName: keyVaultName
    userObjectId: userObjectId
    secretName: keyVaultFunctionKeySecretName
    secretValue: functionXFunctionsKey
  }
}

/*
  Foundry project connection used by the agent OpenAPI tool to call Azure Functions.
  Stores a custom header key named 'x-functions-key'.
*/
resource functionProjectConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(functionXFunctionsKey)) {
  name: functionProjectConnectionName
  parent: aiProject
  properties: {
    category: 'CustomKeys'
    authType: 'CustomKeys'
    target: 'https://${functionApp.outputs.functionAppDefaultHostname}'
    isSharedToAll: true
    credentials: {
      keys: {
        'x-functions-key': functionXFunctionsKey
      }
    }
  }
}

/* --------------------------------- Grant RBAC   -------------------------------------- */

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    userObjectId: userObjectId
    userPrincipalType: userPrincipalType
    searchServiceName: searchName
    searchServicePrincipalId: searchService.identity.principalId
    aiFoundryName: aiFoundryName
    aiProjectName: aiProjectName
    storageAccountName: saName
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
    functionAppName: functionAppName
    grantFunctionKeySetterContributor: !empty(functionXFunctionsKey)
    functionKeySetterPrincipalId: functionKeySetterIdentity.properties.principalId
  }
  dependsOn: [
    aiFoundry
    storage
  ]
}

@description('True when functionXFunctionsKey was provided (non-empty) during deployment.')
#disable-next-line outputs-should-not-contain-secrets
output functionKeyProvided bool = !empty(functionXFunctionsKey)

@description('True when the deployment would create/run the Function host-key setter script resource.')
#disable-next-line outputs-should-not-contain-secrets
output willRunFunctionHostKeySetter bool = !empty(functionXFunctionsKey)

@description('True when the Foundry Project connection resource would be created/updated.')
#disable-next-line outputs-should-not-contain-secrets
output willCreateFunctionProjectConnection bool = !empty(functionXFunctionsKey)

@description('True when Key Vault secret creation is enabled and function key is provided.')
#disable-next-line outputs-should-not-contain-secrets
output willCreateKeyVaultSecret bool = createKeyVault && !empty(keyVaultName) && !empty(functionXFunctionsKey)
