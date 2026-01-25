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

$rg = "rg-dev-insurance-assistant"
$loc = "swedencentral"

# Paths relative to the scripts folder
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$bicepFile = Join-Path $repoRoot "infra\bicep\main.bicep"

if (-not (Test-Path $bicepFile)) {
  throw "Nie znaleziono pliku Bicep: $bicepFile"
}

$userOid = az ad signed-in-user show --query id -o tsv

az group create -n $rg -l $loc | Out-Null

az deployment group create `
  -g $rg `
  -n "deployment-ins-assistant" `
  -f $bicepFile `
  -p userObjectId=$userOid

Write-Host "`nDone."
