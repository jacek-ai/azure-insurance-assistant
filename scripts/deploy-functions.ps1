<#
.SYNOPSIS
    Publishes the Azure Functions code (tools) to an existing Function App.

.DESCRIPTION
    This repo's scripts/deploy.ps1 deploys infrastructure (Bicep) but does not publish Function App code.
    This script publishes the Function App located in src/functions/hello-api using Azure Functions Core Tools.

PREREQUISITES
    - Azure CLI: az (and run: az login)
    - Azure Functions Core Tools: func

EXAMPLES
    .\deploy-functions.ps1
    .\deploy-functions.ps1 -FunctionAppName insast-dev-swedencen-fapp-0001
    .\deploy-functions.ps1 -FunctionAppName insast-dev-swedencen-fapp-0001 -BuildRemote
#>

[CmdletBinding()]
param(
    [string] $FunctionAppName,
    [string] $ResourceGroup = "rg-dev-insurance-assistant",
    [switch] $BuildRemote
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Missing 'az'. Install Azure CLI." }
if (-not (Get-Command func -ErrorAction SilentlyContinue)) { throw "Missing 'func'. Install Azure Functions Core Tools." }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$functionProjectPath = Join-Path $repoRoot "src\functions\hello-api"

if (-not (Test-Path $functionProjectPath)) {
    throw "Function project path not found: $functionProjectPath"
}

if (-not $FunctionAppName) {
    $FunctionAppName = az functionapp list -g $ResourceGroup --query "[0].name" -o tsv
    if (-not $FunctionAppName) {
        throw "No Function App found in resource group '$ResourceGroup'. Pass -FunctionAppName explicitly."
    }
}

Write-Host "Publishing to Function App: $FunctionAppName" -ForegroundColor Cyan

Push-Location $functionProjectPath
try {
    if ($BuildRemote) {
        & func azure functionapp publish $FunctionAppName --build remote
    } else {
        & func azure functionapp publish $FunctionAppName
    }
} finally {
    Pop-Location
}
