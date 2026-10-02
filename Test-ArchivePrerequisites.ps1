#Requires -Version 7.0
<#
.SYNOPSIS
    Check the Windows host for the modules, CLI, and environment variables the archive jobs need.
.DESCRIPTION
    Does not install anything unless -Install is passed. Install attempts require a local administrator and fail closed otherwise.
.PARAMETER Job
    OnPrem, Entra, Schema, or All.
.PARAMETER Install
    Try to install missing RSAT Active Directory tools and the AWS CLI. Still reports permission failures instead of continuing.
#>
[CmdletBinding()]
param(
    [ValidateSet('OnPrem', 'Entra', 'Schema', 'All')]
    [string]$Job = 'All',
    [switch]$Install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Get-Location).Path -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    [void](Test-ArchivePrerequisites -Job $Job -Install:$Install)
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
