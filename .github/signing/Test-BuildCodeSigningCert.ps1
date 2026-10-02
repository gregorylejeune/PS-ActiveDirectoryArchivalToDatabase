# Gate for the self-hosted runner. Refuses to sign unless a code-signing
# certificate in the computer store is usable past the renewal window.
[CmdletBinding()]
param(
    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$Store = 'LocalMachine',

    [int]$RenewWithinDays = 14
)

$ErrorActionPreference = 'Stop'
$now = Get-Date
$deadline = $now.AddDays($RenewWithinDays)

$cert = Get-ChildItem "Cert:\$Store\My" -CodeSigningCert |
    Where-Object {
        $_.HasPrivateKey -and
        $_.NotBefore -le $now -and
        $_.NotAfter -gt $deadline
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    throw "No code-signing certificate in $Store\My is valid past $RenewWithinDays days."
}

$chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
try {
    if (-not $chain.Build($cert)) {
        $status = ($chain.ChainStatus | ForEach-Object { $_.Status }) -join ', '
        throw "Code-signing certificate chain failed: $status"
    }
}
finally {
    $chain.Dispose()
}

Write-Output "Code-signing certificate $($cert.Thumbprint) is valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))."
