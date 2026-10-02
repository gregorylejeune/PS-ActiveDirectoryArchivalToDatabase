# Code signing

This folder holds the adopter-facing signing pieces. The repository does not ship a certificate, and the author does not sign adopter builds. Each fork configures its own signing.

## Files

- `Invoke-AdopterSign.ps1` — stub for the `ci-service` signing provider. Replace it with your own signer. Do not put a token in this file.
- `README.md` — this guide.

## Generate the workflow

Run `New-AdopterBuildPipeline.ps1` from the repo root in your fork. It writes `.github/workflows/ci.yml` with a `workflow_dispatch` input `signing_provider` (falling back to repository variable `SIGNING_PROVIDER`). Allowed values: `none` (default), `pfx`, `azure-key-vault`, `ci-service`.

```powershell
pwsh .\New-AdopterBuildPipeline.ps1
pwsh .\New-AdopterBuildPipeline.ps1 -SigningProvider Pfx -TimestampServer 'http://timestamp.example.com'
pwsh .\New-AdopterBuildPipeline.ps1 -SigningProvider AzureKeyVault -TimestampServer 'http://timestamp.example.com'
pwsh .\New-AdopterBuildPipeline.ps1 -SigningProvider CiService
```

## Modes

| Mode | What you configure |
| --- | --- |
| `none` | Nothing. Default. Local and dev use needs no certificate. |
| `pfx` | Secrets `CODESIGN_PFX_B64` and `CODESIGN_PFX_PASSWORD`. Variable `TIMESTAMP_SERVER`. |
| `azure-key-vault` | Secrets `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` (prefer GitHub OIDC and drop the client secret). Variables `AZURE_KEY_VAULT_URL`, `AZURE_CERT_NAME`, `TIMESTAMP_SERVER`. |
| `ci-service` | Replace `.github/signing/Invoke-AdopterSign.ps1`. Keep that service's token in your secrets, not in the script. |

## Rules

- The timestamp server URL must start with `http://`. PowerShell's `Set-AuthenticodeSignature` does not support HTTPS timestamping.
- Do not reuse an example timestamp URL or thumbprint from upstream. Use your own RFC 3161 server.
- Do not commit a PFX, password, or CA private key. Do not put those values in `README.md` or `AGENTS.md`.
- Do not set execution policy `Bypass` or `Unrestricted` to skip signature checks.
- Do not mint a self-signed certificate in the job. Do not use a developer personal certificate.
- The code-signing certificate needs the Code Signing enhanced key usage and must not be expired.
- The signing certificate is not the Active Directory bind account. SQL stays pass-through.
- The runner account is not a domain admin and does not need SQL rights.

## Verify before deploy

On each archive host, run:

```powershell
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1,*.ps1xml |
  Get-AuthenticodeSignature |
  Where-Object Status -ne 'Valid'
```

That command must return nothing. `NotSigned` is acceptable only when `SIGNING_PROVIDER` is `none`. `HashMismatch` or `UnknownError` stops the deploy. When signing is on, the signer thumbprint must match your own certificate.

For PowerShell execution policy `AllSigned`, the archive host must trust the issuing CA and have the code-signing certificate in Trusted Publishers.

## HSM

An HSM is a hardware or cloud device that holds the private key so the key never leaves it. You only need one if your certificate authority requires a hardware-backed code-signing key. A PFX in your own Actions secrets is acceptable if the workflow writes it under `RUNNER_TEMP`, signs, and deletes it in an `if: always()` step.

## Microsoft guidance

Microsoft's CI/CD signing guidance points at Azure Key Vault with an HSM-backed certificate signed through AzureSignTool, or the Azure Artifact Signing service (about ten dollars a month), which integrates directly with GitHub Actions. Since June 2023, CAs require code-signing keys on FIPS 140-2 Level 2 hardware or better, so the HSM-backed path is the modern default for adopters whose CA requires it.
