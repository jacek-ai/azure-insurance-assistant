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

$namePrefix = "insast-dev-"

# Deleting without question
$forceDeleteRg = $false

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