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

function Invoke-AzGroupDeploymentWithRetry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string] $DeploymentName,

    [Parameter(Mandatory = $true)]
    [string] $TemplateFile,

    [Parameter(Mandatory = $true)]
    [string[]] $Parameters
  )

  $maxAttempts = 10
  $delaySeconds = 45

  if (-not [string]::IsNullOrWhiteSpace($env:DEPLOY_RETRY_MAX_ATTEMPTS)) {
    [void][int]::TryParse($env:DEPLOY_RETRY_MAX_ATTEMPTS, [ref] $maxAttempts)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:DEPLOY_RETRY_DELAY_SECONDS)) {
    [void][int]::TryParse($env:DEPLOY_RETRY_DELAY_SECONDS, [ref] $delaySeconds)
  }

  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Host "Running ARM deployment (attempt $attempt/$maxAttempts)..." -ForegroundColor Cyan

    $output = & az deployment group create `
      -g $ResourceGroup `
      -n $DeploymentName `
      -f $TemplateFile `
      -p @Parameters 2>&1

    if ($LASTEXITCODE -eq 0) {
      return
    }

    $outputText = ($output | Out-String)
    $isProvisioningConflict = (
      $outputText -match 'RequestConflict' -and
      $outputText -match 'provisioning state is not terminal'
    )

    if ($isProvisioningConflict -and $attempt -lt $maxAttempts) {
      Write-Host "Deployment hit a provisioning conflict (resource not in terminal state). Waiting ${delaySeconds}s then retrying..." -ForegroundColor Yellow
      Start-Sleep -Seconds $delaySeconds
      continue
    }

    Write-Host "Deployment failed. Fetching failed operations for diagnostics..." -ForegroundColor Yellow
    try {
      $failedOps = & az deployment group operation list -g $ResourceGroup -n $DeploymentName --query "[?properties.provisioningState=='Failed']" -o json 2>&1
      if ($LASTEXITCODE -eq 0) {
        $failedOpsText = ($failedOps | Out-String)
        if (-not [string]::IsNullOrWhiteSpace($failedOpsText)) {
          Write-Host "Failed operations:\n$failedOpsText" -ForegroundColor DarkYellow
        }
      }
      else {
        $failedOpsText = ($failedOps | Out-String)
        Write-Host "Failed to list deployment operations:\n$failedOpsText" -ForegroundColor DarkYellow
      }
    }
    catch {
      Write-Host ("Failed to query deployment operations: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    throw "Deployment failed. Azure CLI output:\n$outputText"
  }
}

$userOid = $env:USER_OBJECT_ID
$userPrincipalType = ''
if ([string]::IsNullOrWhiteSpace($userOid)) {
  $accountType = az account show --query 'user.type' -o tsv
  $accountName = az account show --query 'user.name' -o tsv

  if ($accountType -eq 'user') {
    $userPrincipalType = 'User'
  }
  elseif ($accountType -eq 'servicePrincipal') {
    $userPrincipalType = 'ServicePrincipal'
  }
  else {
    $userPrincipalType = 'User'
  }

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

if ([string]::IsNullOrWhiteSpace($userPrincipalType)) {
  $accountType = az account show --query 'user.type' -o tsv
  if ($accountType -eq 'servicePrincipal') {
    $userPrincipalType = 'ServicePrincipal'
  } else {
    $userPrincipalType = 'User'
  }
}

if ([string]::IsNullOrWhiteSpace($userOid)) {
  throw 'Unable to determine Entra objectId for RBAC assignment. Set USER_OBJECT_ID env var (recommended for CI), or run with a user login (az login) that can query its profile.'
}

$functionKey = $env:FUNCTION_X_FUNCTIONS_KEY

function Test-EnvBool {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Name,

    [Parameter(Mandatory = $false)]
    [bool] $Default = $false
  )

  $raw = [string][Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $Default
  }

  $value = $raw.Trim().ToLowerInvariant()
  return $value -in @('1','true','yes','y','on')
}

$createKeyVault = Test-EnvBool -Name 'CREATE_KEY_VAULT' -Default $false
$keyVaultName = $env:KEY_VAULT_NAME
$keyVaultSecretName = if (-not [string]::IsNullOrWhiteSpace($env:KEY_VAULT_FUNCTION_KEY_SECRET_NAME)) { $env:KEY_VAULT_FUNCTION_KEY_SECRET_NAME } else { 'functions-host-key-default' }

if ($createKeyVault) {
  if ([string]::IsNullOrWhiteSpace($functionKey)) {
    throw 'CREATE_KEY_VAULT=true requires FUNCTION_X_FUNCTIONS_KEY to be set (host key value to store as a Key Vault secret).'
  }
  if ([string]::IsNullOrWhiteSpace($keyVaultName)) {
    throw 'CREATE_KEY_VAULT=true requires KEY_VAULT_NAME to be set.'
  }
  Write-Host ("Key Vault creation is ENABLED (KEY_VAULT_NAME={0}, KEY_VAULT_FUNCTION_KEY_SECRET_NAME={1})." -f $keyVaultName, $keyVaultSecretName) -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($functionKey)) {
  Write-Host 'FUNCTION_X_FUNCTIONS_KEY is not set (or empty). Deploying WITHOUT functionXFunctionsKey.' -ForegroundColor Yellow
}
else {
  Write-Host ("FUNCTION_X_FUNCTIONS_KEY is set. Deploying WITH functionXFunctionsKey (length: {0})." -f $functionKey.Length) -ForegroundColor Cyan
}

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
      Write-Host 'Bicep deployment parameters: compiled params + userObjectId + userPrincipalType (no functionXFunctionsKey).' -ForegroundColor DarkGray
      Invoke-AzGroupDeploymentWithRetry -ResourceGroup $rg -DeploymentName "deployment-ins-assistant" -TemplateFile $bicepFile -Parameters @(
        "@$compiledParams",
        "userObjectId=$userOid",
        "userPrincipalType=$userPrincipalType"
      )
    }
    else {
      Write-Host 'Bicep deployment parameters: compiled params + userObjectId + userPrincipalType + functionXFunctionsKey.' -ForegroundColor DarkGray
      $parameters = @(
        "@$compiledParams",
        "userObjectId=$userOid",
        "userPrincipalType=$userPrincipalType",
        "functionXFunctionsKey=$functionKey"
      )

      if ($createKeyVault) {
        $parameters += "createKeyVault=true"
        $parameters += "keyVaultName=$keyVaultName"
        $parameters += "keyVaultFunctionKeySecretName=$keyVaultSecretName"
      }

      Invoke-AzGroupDeploymentWithRetry -ResourceGroup $rg -DeploymentName "deployment-ins-assistant" -TemplateFile $bicepFile -Parameters $parameters
    }
  }
  finally {
    if (Test-Path $compiledParams) {
      Remove-Item -Force $compiledParams -ErrorAction SilentlyContinue
    }
  }
}
else {
  if ([string]::IsNullOrWhiteSpace($functionKey)) {
    Invoke-AzGroupDeploymentWithRetry -ResourceGroup $rg -DeploymentName "deployment-ins-assistant" -TemplateFile $bicepFile -Parameters @(
      "userObjectId=$userOid",
      "userPrincipalType=$userPrincipalType"
    )
  }
  else {
    $parameters = @(
      "userObjectId=$userOid",
      "userPrincipalType=$userPrincipalType",
      "functionXFunctionsKey=$functionKey"
    )

    if ($createKeyVault) {
      $parameters += "createKeyVault=true"
      $parameters += "keyVaultName=$keyVaultName"
      $parameters += "keyVaultFunctionKeySecretName=$keyVaultSecretName"
    }

    Invoke-AzGroupDeploymentWithRetry -ResourceGroup $rg -DeploymentName "deployment-ins-assistant" -TemplateFile $bicepFile -Parameters $parameters
  }
}

Write-Host "`nDone."
