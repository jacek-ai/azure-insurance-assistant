<#
.SYNOPSIS
    Runs the repo test suite (CI-friendly).

.DESCRIPTION
    - Creates a local virtual environment if missing (.venv)
    - Installs test dependencies from requirements-dev.txt
    - Runs pytest

    The script returns pytest's exit code, so it can be used in CI/CD.

.EXAMPLE
    .\scripts\test.ps1

.EXAMPLE
    .\scripts\test.ps1 -RecreateVenv

.EXAMPLE
    .\scripts\test.ps1 -PythonExe "C:\Python312\python.exe"
#>

[CmdletBinding()]
param(
  [string] $PythonExe,
  [string] $VenvDir = ".venv",
  [switch] $RecreateVenv,
  [switch] $UpgradePip
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
Import-DotEnv -NoClobber

function Get-IsWindows {
  try {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
      [System.Runtime.InteropServices.OSPlatform]::Windows
    )
  } catch {
    # Windows PowerShell 5.1 fallback
    return $env:OS -eq 'Windows_NT'
  }
}

function Assert-ExitCode([string] $What) {
  if ($LASTEXITCODE -ne 0) {
    throw "$What failed with exit code $LASTEXITCODE"
  }
}

function Resolve-PythonExe {
  param([string] $Requested)

  if (-not [string]::IsNullOrWhiteSpace($Requested)) {
    if (-not (Test-Path $Requested)) {
      throw "PythonExe not found: $Requested"
    }
    return $Requested
  }

  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py) { return $py.Source }

  $py3 = Get-Command python3 -ErrorAction SilentlyContinue
  if ($py3) { return $py3.Source }

  throw "Python executable not found. Install Python or pass -PythonExe."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  $python = Resolve-PythonExe -Requested $PythonExe

  if ($RecreateVenv -and (Test-Path $VenvDir)) {
    Remove-Item -Recurse -Force $VenvDir
  }

  if (-not (Test-Path $VenvDir)) {
    Write-Host "Creating venv: $VenvDir" -ForegroundColor Cyan
    & $python -m venv $VenvDir
    Assert-ExitCode "python -m venv"
  }

  $isWindows = Get-IsWindows
  $venvPython = if ($isWindows) {
    Join-Path $VenvDir "Scripts\python.exe"
  } else {
    Join-Path $VenvDir "bin/python"
  }

  if (-not (Test-Path $venvPython)) {
    throw "Venv python not found: $venvPython"
  }

  if ($UpgradePip) {
    & $venvPython -m pip install --upgrade pip
    Assert-ExitCode "pip upgrade"
  }

  if (-not (Test-Path "requirements-dev.txt")) {
    throw "requirements-dev.txt not found in repo root"
  }

  Write-Host "Installing test dependencies" -ForegroundColor Cyan
  & $venvPython -m pip install -r requirements-dev.txt
  Assert-ExitCode "pip install requirements-dev.txt"

  Write-Host "Running pytest" -ForegroundColor Cyan
  & $venvPython -m pytest
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
