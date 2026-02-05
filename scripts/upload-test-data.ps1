<#
.SYNOPSIS
    Uploads local test data to Azure Storage blob containers.

.DESCRIPTION
    Uploads:
      - test/test-data/products.json to the 'products' container
      - all files from test/test-data/OWU to the 'rag-data' container

    This script uses Azure CLI and a Storage Account key (retrieved via Azure CLI)
    so it works even if you do not have Storage Blob Data roles assigned.

.EXAMPLE
    .\scripts\upload-test-data.ps1

.EXAMPLE
    .\scripts\upload-test-data.ps1 -ResourceGroupName rg-dev-insurance-assistant -StorageAccountName insastdevswedencen0001

.EXAMPLE
    .\scripts\upload-test-data.ps1 -OwuPrefix 'OWU'
#>

[CmdletBinding()]
param(
  [string]$ResourceGroupName = $(if (-not [string]::IsNullOrWhiteSpace($env:RESOURCE_GROUP_NAME)) { $env:RESOURCE_GROUP_NAME } else { 'rg-dev-insurance-assistant' }),
  [string]$StorageAccountName = $(if (-not [string]::IsNullOrWhiteSpace($env:STORAGE_ACCOUNT_NAME)) { $env:STORAGE_ACCOUNT_NAME } else { 'insastdevswedencen0001' }),

  [string]$ProductsContainerName = 'products',
  [string]$RagDataContainerName = 'rag-data',

  [string]$ProductsBlobName = 'products.json',

  # Optional prefix inside the rag-data container (e.g. 'OWU')
  [string]$OwuPrefix = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
Import-DotEnv -NoClobber

function Assert-PathExists([string]$Path, [string]$Label) {
  if (-not (Test-Path $Path)) {
    throw "$Label not found: $Path"
  }
}

Assert-AzCliLoggedIn

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$productsFilePath = Join-Path $repoRoot 'test\test-data\products.json'
$owuFolderPath = Join-Path $repoRoot 'test\test-data\OWU'

Assert-PathExists $productsFilePath 'Products file'
Assert-PathExists $owuFolderPath 'OWU folder'

Write-Host '--- Resolving Storage Account key ---'
$accountKey = az storage account keys list -g $ResourceGroupName -n $StorageAccountName --query '[0].value' -o tsv
if ([string]::IsNullOrWhiteSpace($accountKey)) {
  throw "Unable to retrieve Storage Account key for $StorageAccountName in $ResourceGroupName."
}

Write-Host '--- Ensuring containers exist ---'
$null = az storage container create --name $ProductsContainerName --account-name $StorageAccountName --account-key $accountKey -o none
$null = az storage container create --name $RagDataContainerName --account-name $StorageAccountName --account-key $accountKey -o none

Write-Host "--- Uploading $productsFilePath -> container '$ProductsContainerName' ---"
$null = az storage blob upload `
  --account-name $StorageAccountName `
  --account-key $accountKey `
  --container-name $ProductsContainerName `
  --name $ProductsBlobName `
  --file $productsFilePath `
  --overwrite true `
  -o none

Write-Host "--- Uploading OWU folder -> container '$RagDataContainerName' ---"
if ([string]::IsNullOrWhiteSpace($OwuPrefix)) {
  $null = az storage blob upload-batch `
    --account-name $StorageAccountName `
    --account-key $accountKey `
    --destination $RagDataContainerName `
    --source $owuFolderPath `
    --overwrite true `
    -o none
}
else {
  # Note: --destination-path is supported on newer Azure CLI versions.
  # If your CLI is older, remove --destination-path and re-run.
  $null = az storage blob upload-batch `
    --account-name $StorageAccountName `
    --account-key $accountKey `
    --destination $RagDataContainerName `
    --destination-path $OwuPrefix `
    --source $owuFolderPath `
    --overwrite true `
    -o none
}

Write-Host "`nDone."
