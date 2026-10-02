#Requires -Version 7.0
<#
.SYNOPSIS
    Non-interactive renewal for the build-server code-signing certificate.
.DESCRIPTION
    Tests the current certificate. If it is missing or inside the renewal window,
    pulses autoenrollment and, if still missing, enrolls the named template.
    Exports only the public certificate for Group Policy. Never writes a PFX.
    This script must not prompt. The scheduled task calls it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,64}$')]
    [string]$TemplateName,

    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$Store = 'LocalMachine',

    [ValidateRange(1, 90)]
    [int]$RenewWithinDays = 14,

    [string]$PublicCertDrop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$testScript = Join-Path $here 'Test-BuildCodeSigningCert.ps1'
if (-not (Test-Path -LiteralPath $testScript)) {
    throw "Missing $testScript"
}

$logDir = Join-Path $env:ProgramData 'CodeSigningRenewal\logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logPath = Join-Path $logDir 'renewal.log'

function Write-RenewalAudit {
    param([string]$Message)
    $line = '{0:o} {1}' -f [datetime]::UtcNow, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
    Write-Output $line
}

function Get-ValidCert {
    try {
        return (& $testScript -Store $Store -RenewWithinDays $RenewWithinDays)
    }
    catch {
        Write-RenewalAudit -Message "Validity check failed. $($_.Exception.Message)"
        return $null
    }
}

try {
    $cert = Get-ValidCert
    if (-not $cert) {
        Write-RenewalAudit -Message 'Pulsing certificate autoenrollment.'
        & certutil.exe -pulse
        if ($LASTEXITCODE -ne 0) {
            Write-RenewalAudit -Message "certutil -pulse exited $LASTEXITCODE"
        }
        $cert = Get-ValidCert
    }

    if (-not $cert) {
        Write-RenewalAudit -Message "Enrolling template $TemplateName into $Store."
        $enrollArgs = @('-enroll', '-q', $TemplateName)
        if ($Store -eq 'LocalMachine') { $enrollArgs = @('-enroll', '-machine', '-q', $TemplateName) }
        & certreq.exe @enrollArgs
        if ($LASTEXITCODE -ne 0) {
            throw "certreq -enroll exited $LASTEXITCODE for template $TemplateName."
        }
        $cert = Get-ValidCert
    }

    if (-not $cert) {
        throw "No usable code-signing certificate after autoenrollment and certreq. Template=$TemplateName Store=$Store."
    }

    if ($PublicCertDrop) {
        if (-not (Test-Path -LiteralPath $PublicCertDrop)) {
            New-Item -ItemType Directory -Path $PublicCertDrop -Force | Out-Null
        }
        $cerPath = Join-Path $PublicCertDrop 'build-codesigning.cer'
        Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT -Force | Out-Null
        Write-RenewalAudit -Message "Exported public certificate only to $cerPath"
    }

    Write-RenewalAudit -Message ("Renewal ok thumbprint={0} notAfter={1:o}" -f $cert.Thumbprint, $cert.NotAfter)
}
catch {
    Write-RenewalAudit -Message "Renewal failed. $($_.Exception.Message)"
    if ($PSVersionTable.PSVersion.Major -ge 5) {
        Write-EventLog -LogName Application -Source 'Application' -EventId 4701 -EntryType Error -Message $_.Exception.Message -ErrorAction SilentlyContinue
    }
    exit 1
}
