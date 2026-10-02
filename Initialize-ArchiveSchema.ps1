#Requires -Version 5.1
<#
.SYNOPSIS
    Create the SQL Server archive schema used by the on-prem and Entra jobs.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Get-Location).Path -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'module\PS-ActiveDirectoryArchivalToDatabase.psm1'
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Initialize-ArchiveDatabase -SchemaFile (Join-Path (Split-Path $modulePath -Parent) '..\sql\001_create_archive_schema.sql')
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
