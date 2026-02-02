@description('Azure region')
param location string

@description('Key Vault name')
param keyVaultName string

@description('Entra ID tenant id')
param tenantId string = subscription().tenantId

@description('ObjectId of a user/admin that should be able to manage secrets')
param userObjectId string

@description('Secret name to create/update')
param secretName string

@secure()
@description('Secret value')
param secretValue string

var roleKeyVaultSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource userSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, userObjectId, roleKeyVaultSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsOfficer)
    principalId: userObjectId
    principalType: 'User'
  }
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  name: secretName
  parent: keyVault
  properties: {
    value: secretValue
  }
  dependsOn: [
    userSecretsOfficer
  ]
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output secretName string = secret.name
