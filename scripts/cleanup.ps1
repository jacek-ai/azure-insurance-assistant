<#
.SYNOPSIS
    Deletes Azure Insurance Assistant resource group and purges soft-deleted Cognitive Services.

.DESCRIPTION
    Removes the resource group and purges any soft-deleted AI services in swedencentral
    to allow redeployment with the same resource names.

.EXAMPLE
    .\cleanup.ps1
#>

$ErrorActionPreference = "Stop"

$rg  = "rg-dev-insurance-assistant"
$loc = "swedencentral"

# Key Vault used by this project (explicit name to avoid deleting anything else)
$keyVaultName = "insastdevswedencenkv0001"

$namePrefix = "insast-dev-"

# Deleting without question
$forceDeleteRg = $false

Write-Host "=== Key Vault cleanup (safe: exact name match only) ==="
Write-Host "Target Key Vault: $keyVaultName"

# 1) If Key Vault currently exists (active), delete it.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$kvId = az keyvault show --only-show-errors --name $keyVaultName --query id -o tsv 2>$null
$kvShowExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($kvShowExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($kvId)) {
  Write-Host "Key Vault exists. Deleting: $keyVaultName" -ForegroundColor Yellow
  az keyvault delete --name $keyVaultName -o none
  if ($LASTEXITCODE -ne 0) { throw "Key Vault delete failed for $keyVaultName" }
  Write-Host "Delete requested." -ForegroundColor Cyan
}
else {
  Write-Host "Key Vault does not exist (active): $keyVaultName" -ForegroundColor DarkGray
}

# 2) If Key Vault exists in soft-deleted state (exact name), purge it.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$deletedJsonText = az keyvault list-deleted --only-show-errors --query "[?name=='$keyVaultName'] | [0]" -o json 2>$null
$kvListDeletedExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap

$deleted = $null
if ($kvListDeletedExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($deletedJsonText)) {
  $deleted = $deletedJsonText | ConvertFrom-Json
}

if ($deleted -and $deleted.name -eq $keyVaultName) {
  $deletedLocation = $deleted.properties.location
  if ([string]::IsNullOrWhiteSpace($deletedLocation)) {
    throw "Key Vault '$keyVaultName' is soft-deleted but location could not be determined."
  }

  Write-Host "Key Vault is soft-deleted. Purging: $keyVaultName (location: $deletedLocation)" -ForegroundColor Yellow
  az keyvault purge --name $keyVaultName --location $deletedLocation -o none
  if ($LASTEXITCODE -ne 0) {
    throw "Key Vault purge failed for $keyVaultName. If purge protection is enabled, purge is not possible until retention expires (use recover or change the name)."
  }
  Write-Host "Purged." -ForegroundColor Cyan
}
else {
  Write-Host "Key Vault is not in soft-deleted state: $keyVaultName" -ForegroundColor DarkGray
}

Write-Host "=== Deleting resource group: $rg ==="

if ($forceDeleteRg) {
  az group delete -n $rg --yes --no-wait
} else {
  az group delete -n $rg
}

Write-Host "RG delete requested. Waiting a bit for Azure to register deletions..."
Start-Sleep -Seconds 10

Write-Host "`n=== Listing soft-deleted Cognitive Services accounts ==="
$deletedJson = az cognitiveservices account list-deleted -o json | ConvertFrom-Json

if (-not $deletedJson -or $deletedJson.Count -eq 0) {
  Write-Host "No soft-deleted Cognitive Services accounts found."
  exit 0
}

# Filtering soft deleted resources
$targets = $deletedJson | Where-Object {
  ($_.location -eq $loc) -and
  (
    [string]::IsNullOrWhiteSpace($namePrefix) -or
    ($_.name -like "$namePrefix*")
  )
}

if (-not $targets -or $targets.Count -eq 0) {
  Write-Host "No soft-deleted Cognitive Services accounts in location '$loc' matching prefix '$namePrefix'."
  Write-Host "If you expected something, run: az cognitiveservices account list-deleted -o table"
  exit 0
}

Write-Host "Found $($targets.Count) soft-deleted account(s) to purge:"
$targets | Select-Object name, location | Format-Table

foreach ($t in $targets) {
  $n = $t.name
  Write-Host "`nPurging: name='$n' location='$loc' (rg parameter required by az even if RG is deleted)"
  az cognitiveservices account purge -g $rg -l $loc -n $n
  if ($LASTEXITCODE -ne 0) { throw "Purge failed for $n" }
}

Write-Host "`nDone."