# Signs the archival scripts with the runner machine-store certificate, then copies
# the tree only if every signature is Valid. Does not read or write a PFX.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$DropPath,

    [Parameter(Mandatory)]
    [string]$TimestampServer
)

$ErrorActionPreference = 'Stop'

if ($TimestampServer -notmatch '^http://') {
    throw 'TimestampServer must start with http://.'
}

& (Join-Path $PSScriptRoot 'Test-BuildCodeSigningCert.ps1')

$now = Get-Date
$cert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert |
    Where-Object { $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -gt $now } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    throw 'No usable code-signing certificate in LocalMachine\My.'
}

$files = @(Get-ChildItem -Path $SourcePath -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml |
    Where-Object { $_.FullName -notmatch '\\\.git\\' })

if (-not $files) {
    throw "No script files found under $SourcePath."
}

foreach ($file in $files) {
    $sig = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $TimestampServer
    if ($sig.Status -ne 'Valid') {
        throw "$($file.Name) signature status $($sig.Status)."
    }
}

$bad = @($files | Get-AuthenticodeSignature | Where-Object Status -ne 'Valid')
if ($bad) {
    throw 'Signature check failed after signing.'
}

$dest = Join-Path $DropPath $env:GITHUB_SHA
if ([string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
    $dest = Join-Path $DropPath (Get-Date -Format 'yyyyMMdd-HHmmss')
}
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -Path (Join-Path $SourcePath '*') -Destination $dest -Recurse -Force
Write-Output "Signed $($files.Count) files and copied them to $dest."
