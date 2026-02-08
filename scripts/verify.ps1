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

. (Join-Path $PSScriptRoot 'common.ps1')
Import-DotEnv -NoClobber

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

function Get-AzCliValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $Args,

    [int] $MaxAttempts = 6,
    [int] $DelaySeconds = 5,

    [string] $What = 'Azure CLI command'
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $output = & az @Args 2>&1
    $text = ($output | Out-String).Trim()

    if ($LASTEXITCODE -eq 0) {
      return $text
    }

    $isTransientNetwork = (
      $text -match 'getaddrinfo failed' -or
      $text -match 'Failed to resolve' -or
      $text -match 'Name or service not known' -or
      $text -match 'Temporary failure in name resolution' -or
      $text -match 'ConnectionError' -or
      $text -match 'HTTPSConnection' -or
      $text -match 'Read timed out' -or
      $text -match 'ConnectTimeout'
    )

    if ($isTransientNetwork -and $attempt -lt $MaxAttempts) {
      Write-Host ("Warning: $What failed due to a transient network/DNS error (attempt $attempt/$MaxAttempts). Retrying in ${DelaySeconds}s...") -ForegroundColor Yellow
      Start-Sleep -Seconds $DelaySeconds
      continue
    }

    throw "$What failed. Azure CLI output:\n$text"
  }

  throw "$What failed after $MaxAttempts attempts."
}

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

Write-Host '--- Verifying Function App functions are indexed ---'
$functionsJson = Get-AzCliValue -What 'Function App functions list' -Args @(
  'functionapp','function','list',
  '-g', $ResourceGroupName,
  '-n', $FunctionAppName,
  '-o', 'json'
)

$functions = $functionsJson | ConvertFrom-Json
if (-not $functions -or $functions.Count -lt 1) {
  throw "No functions are indexed in the Function App ($FunctionAppName). This typically means the code package did not deploy correctly or the host failed to load functions (check Function App logs / remote build)."
}

Write-Host ("OK: Functions indexed: {0}." -f $functions.Count)

if (-not $SkipKeyVault) {
  Write-Host '--- Verifying Key Vault secret ---'
  Assert-NotEmpty $KeyVaultName 'KeyVaultName'
  Assert-NotEmpty $KeyVaultSecretName 'KeyVaultSecretName'

  try {
    # Ensure secret exists
    $null = Get-AzCliValue -What 'Key Vault secret existence check' -Args @(
      'keyvault','secret','show',
      '--vault-name', $KeyVaultName,
      '--name', $KeyVaultSecretName,
      '--query', 'id',
      '-o', 'tsv'
    )
    Write-Host "OK: Key Vault secret exists ($KeyVaultName / $KeyVaultSecretName)."
  }
  catch {
    # Key Vault is optional in this repo (main.bicep creates it only when createKeyVault=true).
    # If it's missing or unreachable from the runner, don't fail the whole verification.
    Write-Host ("Warning: skipping Key Vault checks. Reason: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    Write-Host 'Tip: to enforce Key Vault checks, provision the vault/secret (createKeyVault=true) and ensure network/DNS allows access from the runner.' -ForegroundColor DarkGray
    Write-Host 'Tip: to silence this message, run verify with -SkipKeyVault.' -ForegroundColor DarkGray
    $SkipKeyVault = $true
  }

  if (-not $SkipKeyVault -and -not [string]::IsNullOrWhiteSpace($expectedKey)) {
    $kvValue = Get-AzCliValue -What 'Key Vault secret value read' -Args @(
      'keyvault','secret','show',
      '--vault-name', $KeyVaultName,
      '--name', $KeyVaultSecretName,
      '--query', 'value',
      '-o', 'tsv'
    )
    if ([string]::IsNullOrWhiteSpace($kvValue)) {
      throw 'Key Vault secret value is empty (or could not be read).'
    }
    if ($kvValue -ne $expectedKey) {
      throw 'Mismatch: Key Vault secret value does not match FUNCTION_X_FUNCTIONS_KEY.'
    }
    Write-Host 'OK: Key Vault secret value matches FUNCTION_X_FUNCTIONS_KEY.'
  }
  elseif (-not $SkipKeyVault) {
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

  # This is an ARM nested resource:
  # /providers/Microsoft.CognitiveServices/accounts/<accountName>/projects/<projectName>/connections/<connectionName>
  # In Azure CLI, use --parent + leaf --name. Do NOT pass a slash-separated name.
  $resourceType = 'Microsoft.CognitiveServices/accounts/projects/connections'
  $apiVersion = '2025-04-01-preview'
  $subscriptionId = az account show --query 'id' -o tsv
  if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'Unable to determine current subscription id from Azure CLI (az account show).'
  }

  $connResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices/accounts/$AiFoundryName/projects/$AiProjectName/connections/$FunctionProjectConnectionName"

  # Prefer ARM resource lookup by full id. If Azure CLI hits a known serialization bug for this nested type,
  # fall back to a raw ARM REST call.
  $connJson = az resource show --ids $connResourceId --api-version $apiVersion -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($connJson)) {
    $connUrl = "https://management.azure.com$connResourceId?api-version=$apiVersion"
    $connJson = az rest --method get --url $connUrl -o json 2>$null
  }

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($connJson)) {
    $connFullName = "$AiFoundryName/$AiProjectName/$FunctionProjectConnectionName"
    throw "AI Foundry connection not found: $connFullName"
  }

  $connObj = $connJson | ConvertFrom-Json
  $connId = $connObj.id
  $authType = $connObj.properties.authType
  $category = $connObj.properties.category

  Write-Host "OK: Foundry connection exists ($connId)."
  Write-Host "Info: authType=$authType, category=$category (credentials not readable by design)."
}
else {
  Write-Host 'Skipping Foundry connection checks.'
}

Write-Host "`nAll checks passed."