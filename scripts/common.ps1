<#
.SYNOPSIS
    Shared helpers for scripts in this repository.

.DESCRIPTION
    Provides:
    - Repo-root resolution
    - Loading a .env file into process environment variables (no-clobber)
    - Common assertion helpers

    Precedence philosophy:
      explicit script parameters > already-set environment variables > .env file > script defaults

    The .env file is optional. If present, it should be located at repo root.
    Start from .env-template:
      copy .env-template -> .env
#>

function Get-RepoRoot {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
  return $repoRoot.Path
}

function Import-DotEnv {
  [CmdletBinding()]
  param(
    [string] $Path = (Join-Path (Get-RepoRoot) '.env'),
    [switch] $NoClobber
  )

  if (-not (Test-Path $Path)) {
    return
  }

  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
  foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    if ($trimmed.StartsWith('#')) { continue }

    $eq = $trimmed.IndexOf('=')
    if ($eq -lt 1) { continue }

    $name = $trimmed.Substring(0, $eq).Trim()
    $value = $trimmed.Substring($eq + 1)

    if ([string]::IsNullOrWhiteSpace($name)) { continue }

    # Strip optional surrounding quotes.
    $value = $value.Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      if ($value.Length -ge 2) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }

    if ($NoClobber -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
      continue
    }

    [Environment]::SetEnvironmentVariable($name, $value)
  }
}

function Assert-NotEmpty {
  param(
    [string] $Value,
    [string] $Name
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "Missing required value: $Name"
  }
}

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
