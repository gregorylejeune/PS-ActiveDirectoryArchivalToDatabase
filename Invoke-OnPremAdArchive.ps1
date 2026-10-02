#Requires -Version 7.0
<#
.SYNOPSIS
    Archive every on-premises Active Directory user into SQL Server staging, then merge into the system-versioned archive.
.DESCRIPTION
    Does not delete users. Pass a domain DNS name, not a domain controller. The job discovers a controller, pins the read to that host, and audits which controller answered.
.PARAMETER Domain
    Domain DNS name, such as glejeune.org. Omit it to use the domain the Windows account is logged into.
#>
[CmdletBinding()]
param(
    [string]$Domain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Get-Location).Path -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Invoke-OnPremArchive -Domain $Domain
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
