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

function Assert-AzCliReady {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed or not on PATH. Install Azure CLI and try again."
  }

  try {
    $null = az account show -o none 2>$null
  }
  catch {
    throw "You are not logged in to Azure CLI. Run: az login (and optionally: az account set -s <subscriptionId>)"
  }
}

$rg = "rg-dev-insurance-assistant"
$loc = "swedencentral"

# Paths relative to the scripts folder
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$bicepFile = Join-Path $repoRoot "infra\bicep\main.bicep"
$bicepParamFile = Join-Path $repoRoot "infra\bicep\main.bicepparam"

if (-not (Test-Path $bicepFile)) {
  throw "Bicep file not found: $bicepFile"
}

Assert-AzCliReady

$userOid = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($userOid)) {
  throw 'Unable to get signed-in user object id. Make sure you are logged in (az login) and have permission to query your profile.'
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
