@description('ObjectId logged in user (Entra ID)')
param userObjectId string

@description('Location of all resources')
param location string = resourceGroup().location

// Resource names
var searchName    = 'insast-dev-swedencen-srch-0001'
var aiFoundryName = 'insast-dev-swedencen-ai-0001'
var aiProjectName = 'insast-dev-swedencen-proj-0001'
var saName        = 'insastdevswedencen0001'

// RBAC role ids
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7' // Search Index Data Contributor
var roleSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader
var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
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

/*
  Storage module deployment
*/
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: saName
    containerName: 'rag-data'
    readerPrincipalId: searchService.identity.principalId
  }
}

/* --------------------------------- Grant RBAC   -------------------------------------- */

/*
  RBAC: Allow Azure AI Search service's managed identity to call Azure OpenAI (for enrichment/ingestion embeddings)
  Role: Cognitive Services OpenAI User
*/
resource searchToOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundry.id, searchService.id, roleCognitiveServicesOpenAIUser)
  scope: aiFoundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

/*
  RBAC: Allow logged in user to use Azure AI Search indexes (read/write)
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
  RBAC: Allow logged in user to use Azure AI Search indexes (read only)
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

output storageAccountId string = storage.outputs.storageAccountId
output containerId string = storage.outputs.containerId
