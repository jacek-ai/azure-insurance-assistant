<#
.SYNOPSIS
    Deploys Azure Insurance Assistant infrastructure using Bicep.

.DESCRIPTION
    Creates resource group and deploys all Azure resources (Foundry, AI Search, 
    OpenAI, Storage). Automatically assigns current user 
    permissions via their Azure AD object ID.

.EXAMPLE
    .\deploy.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')
Import-DotEnv -NoClobber
$rg = if (-not [string]::IsNullOrWhiteSpace($env:RESOURCE_GROUP_NAME)) { $env:RESOURCE_GROUP_NAME } else { "rg-dev-insurance-assistant" }
$loc = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_LOCATION)) { $env:AZURE_LOCATION } else { "swedencentral" }

# Paths relative to the scripts folder
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$bicepFile = Join-Path $repoRoot "infra\bicep\main.bicep"
$bicepParamFile = Join-Path $repoRoot "infra\bicep\main.bicepparam"

if (-not (Test-Path $bicepFile)) {
  throw "Bicep file not found: $bicepFile"
}

Assert-AzCliLoggedIn

$userOid = $env:USER_OBJECT_ID
if ([string]::IsNullOrWhiteSpace($userOid)) {
  $accountType = az account show --query 'user.type' -o tsv
  $accountName = az account show --query 'user.name' -o tsv

  if ($accountType -eq 'user') {
    $userOid = az ad signed-in-user show --query id -o tsv
  }
  elseif ($accountType -eq 'servicePrincipal') {
    # In GitHub Actions with azure/login (OIDC), az is logged in as a service principal.
    # Try to resolve its object id (requires directory read permissions).
    if (-not [string]::IsNullOrWhiteSpace($accountName)) {
      $userOid = az ad sp show --id $accountName --query id -o tsv
    }
  }
  else {
    # Unknown/unsupported account type (e.g., managed identity in some environments)
    $userOid = ''
  }
}

if ([string]::IsNullOrWhiteSpace($userOid)) {
  throw 'Unable to determine Entra objectId for RBAC assignment. Set USER_OBJECT_ID env var (recommended for CI), or run with a user login (az login) that can query its profile.'
}

$functionKey = $env:FUNCTION_X_FUNCTIONS_KEY

az group create -n $rg -l $loc | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to create or access resource group '$rg'."
}

if (Test-Path $bicepParamFile) {
  # NOTE: `az deployment group create -f` expects a template (bicep/json), not a .bicepparam file.
  # We compile the .bicepparam to a JSON parameters file first.
  $compiledParams = Join-Path $env:TEMP ("main.parameters.{0}.json" -f ([guid]::NewGuid().ToString('N')))
  try {
    az bicep build-params --file $bicepParamFile --outfile $compiledParams | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to compile params file: $bicepParamFile"
    }

    if ([string]::IsNullOrWhiteSpace($functionKey)) {
      az deployment group create `
        -g $rg `
        -n "deployment-ins-assistant" `
        -f $bicepFile `
        -p @$compiledParams userObjectId=$userOid
      if ($LASTEXITCODE -ne 0) { throw 'Deployment failed.' }
    }
    else {
      az deployment group create `
        -g $rg `
        -n "deployment-ins-assistant" `
        -f $bicepFile `
        -p @$compiledParams userObjectId=$userOid functionXFunctionsKey=$functionKey
      if ($LASTEXITCODE -ne 0) { throw 'Deployment failed.' }
    }
  }
  finally {
    if (Test-Path $compiledParams) {
      Remove-Item -Force $compiledParams -ErrorAction SilentlyContinue
    }
  }
}
else {
  az deployment group create `
    -g $rg `
    -n "deployment-ins-assistant" `
    -f $bicepFile `
    -p userObjectId=$userOid
  if ($LASTEXITCODE -ne 0) { throw 'Deployment failed.' }
}

Write-Host "`nDone."
