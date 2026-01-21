param foundryName string

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource gpt4o 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiFoundry
  name: 'gpt-4o'
  sku: {
    capacity: 5
    name: 'GlobalStandard'
  }
  properties: {
    model: {
      name: 'gpt-4o'
      format: 'OpenAI'
    }
  }
}

resource embed 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiFoundry
  name: 'text-embedding-3-small'
  dependsOn: [
    gpt4o
  ]
  sku: {
    capacity: 200
    name: 'GlobalStandard'
  }
  properties: {
    model: {
      name: 'text-embedding-3-small'
      format: 'OpenAI'
    }
  }
}
