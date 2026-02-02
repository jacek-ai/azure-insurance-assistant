@description('ObjectId logged in user (Entra ID)')
param userObjectId string

@description('Name of the Azure AI Search service')
param searchServiceName string

@description('Principal ID of the Azure AI Search managed identity')
param searchServicePrincipalId string

@description('Name of the Azure AI Foundry account (Microsoft.CognitiveServices/accounts)')
param aiFoundryName string

@description('Name of the Storage Account')
param storageAccountName string

@description('Principal ID of the Function App managed identity')
param functionAppPrincipalId string

@description('Name of the Function App (Microsoft.Web/sites)')
param functionAppName string

@description('Whether to grant Contributor on the Function App to the user-assigned identity that sets function keys during deployment')
param grantFunctionKeySetterContributor bool = false

@description('Principal ID of the user-assigned identity that sets function keys during deployment (used only when grantFunctionKeySetterContributor=true)')
param functionKeySetterPrincipalId string = ''

// RBAC role definition ids
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7' // Search Index Data Contributor
var roleSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader
var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
var roleStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' // Storage Blob Data Reader
var roleContributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
}

resource searchService 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: searchServiceName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource functionAppSite 'Microsoft.Web/sites@2022-09-01' existing = {
  name: functionAppName
}

/*
  RBAC: allow the deployment script identity to set Function App keys
  Role: Contributor (broad, but reliable for key operations)
*/
resource functionKeySetterContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantFunctionKeySetterContributor && !empty(functionKeySetterPrincipalId)) {
  name: guid(functionAppSite.id, functionKeySetterPrincipalId, roleContributor)
  scope: functionAppSite
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleContributor)
    principalId: functionKeySetterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

/*
  RBAC: Allow Azure AI Search service's managed identity to call Azure OpenAI (for enrichment/ingestion embeddings)
  Role: Cognitive Services OpenAI User
*/
resource searchToOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry.id, searchService.id, roleCognitiveServicesOpenAIUser)
  scope: aiFoundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: searchServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

/*
  RBAC: Allow logged-in user to use Azure AI Search indexes (read/write)
  Role: Search Index Data Contributor
*/
resource userSearchIndexContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, userObjectId, roleSearchIndexDataContributor)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: userObjectId
    principalType: 'User'
  }
}

/*
  RBAC: Allow logged-in user to use Azure AI Search indexes (read only)
  Role: Search Index Data Reader
*/
resource userSearchIndexReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, userObjectId, roleSearchIndexDataReader)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    principalId: userObjectId
    principalType: 'User'
  }
}

/*
  RBAC: Allow logged-in user to manage Azure AI Search service configuration (admin operations)
  Role: Search Service Contributor
*/
resource userSearchServiceContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, userObjectId, roleSearchServiceContributor)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: userObjectId
    principalType: 'User'
  }
}

/*
  RBAC: allow Azure AI Search (managed identity) to contribute to blobs in the storage account
  Role: Storage Blob Data Contributor
*/
resource searchBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, searchServicePrincipalId, roleStorageBlobDataContributor)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: searchServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

/*
  RBAC: allow Function App (managed identity) to read blobs from the storage account
  Role: Storage Blob Data Reader
*/
resource functionBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppPrincipalId, roleStorageBlobDataReader)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

/*
  RBAC: allow Function App (managed identity) to read from Azure AI Search index
  Role: Search Index Data Reader
*/
resource functionSearchIndexReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, functionAppPrincipalId, roleSearchIndexDataReader)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}
