#Requires -Version 5.1
<#
.SYNOPSIS
    Archive every on-premises Active Directory user into SQL Server staging, then merge into the system-versioned archive.
.DESCRIPTION
    Does not delete users. Truncates staging at the start of the run. Uses pass-through authentication to SQL Server.
    Permission failures are logged so Active Directory administrators can grant read access.
#>
[CmdletBinding()]
param(
    [string]$Server
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Get-Location).Path -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Invoke-OnPremArchive -Server $Server
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
