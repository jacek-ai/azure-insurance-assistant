@description('Azure region')
param location string

@description('Function App name')
param functionAppName string

@description('Storage account name used for AzureWebJobsStorage')
param storageAccountName string

@description('Azure AI Search endpoint (e.g. https://<service>.search.windows.net)')
param searchServiceEndpoint string

@description('Azure AI Search index name used for RAG retrieval')
param searchIndexName string = 'knowledgesource-index'

@description('Blob container name holding the product catalog')
param productsContainerName string = 'products'

@description('Blob name of the product catalog JSON')
param productsBlobName string = 'products.json'

@description('Python runtime version for Linux Functions')
param pythonVersion string = '3.11'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

var blobAccountUrl = 'https://${storageAccountName}.blob.${environment().suffixes.storage}'

// Required by Kudu/zipdeploy for mounting the content share.
// Must be 3-63 chars, lowercase letters/numbers/hyphens.
var contentShareName = toLower('content-${uniqueString(resourceGroup().id, functionAppName)}')

var storageKey = storageAccount.listKeys().keys[0].value
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'

resource plan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${functionAppName}-plan'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    clientAffinityEnabled: false
    serverFarmId: plan.id
    siteConfig: {
      linuxFxVersion: 'Python|${pythonVersion}'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: contentShareName
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'SEARCH_SERVICE_ENDPOINT'
          value: searchServiceEndpoint
        }
        {
          name: 'SEARCH_INDEX_NAME'
          value: searchIndexName
        }
        {
          name: 'BLOB_ACCOUNT_URL'
          value: blobAccountUrl
        }
        {
          name: 'PRODUCTS_CONTAINER_NAME'
          value: productsContainerName
        }
        {
          name: 'PRODUCTS_BLOB_NAME'
          value: productsBlobName
        }
      ]
    }
  }
}

output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
