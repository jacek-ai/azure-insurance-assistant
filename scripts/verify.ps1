<#
.SYNOPSIS
    Verifies the single-secret deployment wiring.

.DESCRIPTION
    Checks that:
      1) Azure Function App has function key 'default' set (and matches FUNCTION_X_FUNCTIONS_KEY if provided)
      2) Key Vault secret exists (and matches FUNCTION_X_FUNCTIONS_KEY if provided)
      3) AI Foundry Project connection exists

    By default it uses the repo's naming conventions from infra/bicep/main.bicep,
    but everything can be overridden via parameters.

.EXAMPLE
    $env:FUNCTION_X_FUNCTIONS_KEY = "<secret>"
    .\scripts\verify.ps1

.EXAMPLE
    .\scripts\verify.ps1 -ResourceGroupName rg-dev-insurance-assistant -Location swedencentral
#>

[CmdletBinding()]
param(
  [string]$ResourceGroupName = 'rg-dev-insurance-assistant',
  [string]$Location = 'swedencentral',

  [string]$FunctionAppName = 'insast-dev-swedencen-fapp-0001',

  [string]$KeyVaultName = 'insastdevswedencenkv0001',
  [string]$KeyVaultSecretName = 'functions-host-key-default',
  [switch]$SkipKeyVault,

  [string]$AiFoundryName = 'insast-dev-swedencen-ai-0001',
  [string]$AiProjectName = 'insast-dev-swedencen-proj-0001',
  [string]$FunctionProjectConnectionName = 'con-function-insurance-assistance',
  [switch]$SkipFoundryConnection
)

$ErrorActionPreference = 'Stop'

function Assert-AzCliLoggedIn {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is not installed or not on PATH. Install Azure CLI and try again.'
  }

  try {
    $null = az account show -o none 2>$null
  }
  catch {
    throw 'You are not logged in to Azure CLI. Run: az login (and optionally: az account set -s <subscriptionId>)'
  }
}

function Assert-NotEmpty([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "Missing required value: $Name"
  }
}

Assert-AzCliLoggedIn

$expectedKey = $env:FUNCTION_X_FUNCTIONS_KEY

Write-Host '--- Verifying Function App key (default) ---'
Assert-NotEmpty $ResourceGroupName 'ResourceGroupName'
Assert-NotEmpty $FunctionAppName 'FunctionAppName'

$functionKey = az functionapp keys list -g $ResourceGroupName -n $FunctionAppName --query 'functionKeys.default' -o tsv
if ([string]::IsNullOrWhiteSpace($functionKey)) {
  throw "Function App key 'default' was not found for $FunctionAppName in $ResourceGroupName."
}
Write-Host "OK: Function App key 'default' exists."

if (-not [string]::IsNullOrWhiteSpace($expectedKey)) {
  if ($functionKey -ne $expectedKey) {
    throw "Mismatch: Function App key 'default' does not match FUNCTION_X_FUNCTIONS_KEY."
  }
  Write-Host 'OK: Function App key matches FUNCTION_X_FUNCTIONS_KEY.'
}
else {
  Write-Host 'Note: FUNCTION_X_FUNCTIONS_KEY not set; skipping value match check.'
}

if (-not $SkipKeyVault) {
  Write-Host '--- Verifying Key Vault secret ---'
  Assert-NotEmpty $KeyVaultName 'KeyVaultName'
  Assert-NotEmpty $KeyVaultSecretName 'KeyVaultSecretName'

  # Ensure secret exists
  $null = az keyvault secret show --vault-name $KeyVaultName --name $KeyVaultSecretName --query 'id' -o tsv
  Write-Host "OK: Key Vault secret exists ($KeyVaultName / $KeyVaultSecretName)."

  if (-not [string]::IsNullOrWhiteSpace($expectedKey)) {
    $kvValue = az keyvault secret show --vault-name $KeyVaultName --name $KeyVaultSecretName --query 'value' -o tsv
    if ([string]::IsNullOrWhiteSpace($kvValue)) {
      throw 'Key Vault secret value is empty.'
    }
    if ($kvValue -ne $expectedKey) {
      throw 'Mismatch: Key Vault secret value does not match FUNCTION_X_FUNCTIONS_KEY.'
    }
    Write-Host 'OK: Key Vault secret value matches FUNCTION_X_FUNCTIONS_KEY.'
  }
  else {
    Write-Host 'Note: FUNCTION_X_FUNCTIONS_KEY not set; skipping Key Vault value match check.'
  }
}
else {
  Write-Host 'Skipping Key Vault checks.'
}

if (-not $SkipFoundryConnection) {
  Write-Host '--- Verifying AI Foundry Project connection resource exists ---'
  Assert-NotEmpty $AiFoundryName 'AiFoundryName'
  Assert-NotEmpty $AiProjectName 'AiProjectName'
  Assert-NotEmpty $FunctionProjectConnectionName 'FunctionProjectConnectionName'

  # Nested resources use name in the form: <accountName>/<projectName>/<connectionName>
  $connFullName = "$AiFoundryName/$AiProjectName/$FunctionProjectConnectionName"
  $resourceType = 'Microsoft.CognitiveServices/accounts/projects/connections'

  $connId = az resource show -g $ResourceGroupName --resource-type $resourceType --name $connFullName --query 'id' -o tsv
  if ([string]::IsNullOrWhiteSpace($connId)) {
    throw "AI Foundry connection not found: $connFullName"
  }

  $authType = az resource show -g $ResourceGroupName --resource-type $resourceType --name $connFullName --query 'properties.authType' -o tsv
  $category = az resource show -g $ResourceGroupName --resource-type $resourceType --name $connFullName --query 'properties.category' -o tsv

  Write-Host "OK: Foundry connection exists ($connId)."
  Write-Host "Info: authType=$authType, category=$category (credentials not readable by design)."
}
else {
  Write-Host 'Skipping Foundry connection checks.'
}

Write-Host "`nAll checks passed."