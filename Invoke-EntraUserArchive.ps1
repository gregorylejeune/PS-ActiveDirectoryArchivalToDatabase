#Requires -Version 5.1
<#
.SYNOPSIS
    Archive every Microsoft Entra ID user into SQL Server staging, then merge into the system-versioned archive.
.DESCRIPTION
    Separate job from the on-prem archive. Requires AWS_ACCESS_KEY and AWS_SECRET_KEY so the Entra app secret can be read from AWS Secrets Manager.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Get-Location).Path -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Invoke-EntraArchive
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
