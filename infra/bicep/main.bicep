param location string = resourceGroup().location

/*
  An AI Foundry resources
*/
var aiFoundryBase = toLower('ai${uniqueString(resourceGroup().id)}')
var aiFoundryName = take(aiFoundryBase, 18)

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
var aiProjectName string = '${aiFoundryName}-proj'

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
var searchName = take(toLower('searchservice${uniqueString(resourceGroup().id)}'), 24)

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
    disableLocalAuth: true
  }
}

/*
  Storage module deployment
*/
var saName = take(toLower('storageaccount${uniqueString(resourceGroup().id)}'), 24)

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: saName
    containerName: 'rag-data'
    readerPrincipalId: searchService.identity.principalId
  }
}

/*
  RBAC: allow Azure AI Search (managed identity) to use Cognitive Services OpenAI models
  Role: Cognitive Services OpenAI User
*/
var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User

resource searchToOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // name MUST be known at start of deployment -> do NOT use principalId here
  name: guid(aiFoundry.id, searchService.name, cognitiveServicesOpenAIUserRoleId)
  scope: aiFoundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleId)
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountId string = storage.outputs.storageAccountId
output containerId string = storage.outputs.containerId
