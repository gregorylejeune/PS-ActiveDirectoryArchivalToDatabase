#Requires -Version 7.0
<#
.SYNOPSIS
    Archive every Microsoft Entra ID user into SQL Server staging, then merge into the system-versioned archive.
.PARAMETER SecretProvider
    AWS reads AWS Secrets Manager. Azure reads Azure Key Vault. The secret JSON shape is the same either way.
#>
[CmdletBinding()]
param(
    [ValidateSet('AWS', 'Azure')]
    [string]$SecretProvider = 'AWS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Get-Location).Path -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Invoke-EntraArchive -SecretProvider $SecretProvider
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
