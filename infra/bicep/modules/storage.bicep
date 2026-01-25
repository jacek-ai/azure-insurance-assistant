@description('Azure region')
param location string

@description('Storage account name')
param storageAccountName string

@description('Blob container name')
param containerName string = 'data'

@description('Principal ID of the identity that will be granted access to the container')
param readerPrincipalId string

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

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

/*
  RBAC: allow Azure AI Search (managed identity) to contribute to blobs in the storage account
  Role: Storage Blob Data Reader
*/
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource searchBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, readerPrincipalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountId string = storageAccount.id
output containerId string = container.id
