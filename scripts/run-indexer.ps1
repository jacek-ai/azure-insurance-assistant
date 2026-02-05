<#
.SYNOPSIS
    Runs an Azure AI Search indexer on demand.

.DESCRIPTION
    Triggers an indexer run using the Azure AI Search data plane REST API:
      POST {SEARCH_SERVICE_ENDPOINT}/indexers/{name}/run?api-version={version}

    Auth options (in order):
      1) Admin key via -AdminApiKey or $env:SEARCH_ADMIN_API_KEY (api-key header)
      2) Azure AD via Azure CLI token for resource https://search.azure.com (Authorization: Bearer)

    For CI/CD, prefer Azure AD (no shared admin keys) with an identity that has
    appropriate Azure AI Search data-plane roles.

.EXAMPLE
    ./scripts/run-indexer.ps1

.EXAMPLE
    ./scripts/run-indexer.ps1 -IndexerName knowledgesource-indexer -Wait

.EXAMPLE
    $env:SEARCH_SERVICE_ENDPOINT = "https://<service>.search.windows.net"
    $env:SEARCH_API_VERSION = "2025-09-01"
    ./scripts/run-indexer.ps1 -Wait
#>

[CmdletBinding()]
param(
  [string]$SearchServiceEndpoint = $env:SEARCH_SERVICE_ENDPOINT,
  [string]$ApiVersion = $(if (-not [string]::IsNullOrWhiteSpace($env:SEARCH_API_VERSION)) { $env:SEARCH_API_VERSION } else { '2025-09-01' }),

  [string]$IndexerName = 'knowledgesource-indexer',

  [string]$AdminApiKey = $env:SEARCH_ADMIN_API_KEY,

  [switch]$Wait,
  [int]$TimeoutSeconds = 900,
  [int]$PollSeconds = 10
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
Import-DotEnv -NoClobber

function Get-SearchAuthHeaders([string]$AdminKey) {
  $headers = @{
    'Accept' = 'application/json'
    'Content-Type' = 'application/json'
  }

  if (-not [string]::IsNullOrWhiteSpace($AdminKey)) {
    $headers['api-key'] = $AdminKey
    return $headers
  }

  Assert-AzCliLoggedIn
  $token = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Unable to acquire Azure AD token for Azure AI Search (https://search.azure.com).'
  }

  $headers['Authorization'] = "Bearer $token"
  return $headers
}

$SearchServiceEndpoint = if (-not [string]::IsNullOrWhiteSpace($SearchServiceEndpoint)) { $SearchServiceEndpoint } else { $env:SEARCH_SERVICE_ENDPOINT }
$ApiVersion = if (-not [string]::IsNullOrWhiteSpace($ApiVersion)) { $ApiVersion } else { $env:SEARCH_API_VERSION }

Assert-NotEmpty $SearchServiceEndpoint 'SearchServiceEndpoint (or env SEARCH_SERVICE_ENDPOINT / .env)'
Assert-NotEmpty $ApiVersion 'ApiVersion (or env SEARCH_API_VERSION / .env)'
Assert-NotEmpty $IndexerName 'IndexerName'

$base = $SearchServiceEndpoint.TrimEnd('/')
$headers = Get-SearchAuthHeaders -AdminKey $AdminApiKey

$runRequestedAtUtc = [DateTime]::UtcNow
$runUrl = "$base/indexers/$IndexerName/run?api-version=$ApiVersion"

Write-Host "--- Running Azure AI Search indexer '$IndexerName' ---"
Write-Host "POST $runUrl"

try {
  $null = Invoke-RestMethod -Method Post -Uri $runUrl -Headers $headers
}
catch {
  throw "Failed to trigger indexer run. $($_.Exception.Message)"
}

Write-Host 'OK: Run request accepted.'

if (-not $Wait) {
  Write-Host 'Note: -Wait not specified; not polling for completion.'
  return
}

$statusUrl = "$base/indexers/$IndexerName/status?api-version=$ApiVersion"
$deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)

Write-Host "--- Waiting for indexer completion (timeout: ${TimeoutSeconds}s) ---"

while ((Get-Date).ToUniversalTime() -lt $deadline) {
  try {
    $status = Invoke-RestMethod -Method Get -Uri $statusUrl -Headers $headers
  }
  catch {
    throw "Failed to fetch indexer status. $($_.Exception.Message)"
  }

  $last = $status.lastResult
  if ($null -eq $last) {
    Start-Sleep -Seconds $PollSeconds
    continue
  }

  $lastStartUtc = $null
  if ($last.startTime) {
    try {
      $lastStartUtc = ([DateTime]::Parse($last.startTime)).ToUniversalTime()
    }
    catch {
      $lastStartUtc = $null
    }
  }

  # Only consider results for the run we requested (best-effort).
  if ($lastStartUtc -and $lastStartUtc -lt $runRequestedAtUtc.AddSeconds(-10)) {
    Start-Sleep -Seconds $PollSeconds
    continue
  }

  $runStatus = $last.status
  Write-Host "Status: $runStatus (startTime=$($last.startTime), endTime=$($last.endTime))"

  if ($runStatus -eq 'success') {
    Write-Host 'OK: Indexer run completed successfully.'
    return
  }

  if ($runStatus -in @('transientFailure', 'persistentFailure')) {
    $err = $last.errorMessage
    if ([string]::IsNullOrWhiteSpace($err) -and $last.errors) {
      $err = ($last.errors | ConvertTo-Json -Depth 6)
    }
    throw "Indexer run finished with status '$runStatus'. Error: $err"
  }

  Start-Sleep -Seconds $PollSeconds
}

throw "Timed out waiting for indexer completion after ${TimeoutSeconds}s."
