@description('Azure region')
param location string

@description('Storage account name')
param storageAccountName string

@description('Blob container name to store RAG data')
param containerNameRagData string = 'data'

@description('Blob container name to store products definitions')
param containerNameProducts string = 'products'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource containerRag 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: containerNameRagData
  properties: {
    publicAccess: 'None'
  }
}

resource containerProducts 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: containerNameProducts
  properties: {
    publicAccess: 'None'
  }
}
