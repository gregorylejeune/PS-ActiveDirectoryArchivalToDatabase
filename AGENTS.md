# Agent instructions

This repository archives users. It does not delete them, disable them, or change Active Directory or Entra ID.

## Host and layout

- Run with PowerShell 7 (`pwsh`). Scripts require 7.0 or later.
- Entry scripts stay in the repo root. They import one module: `module/PS-ActiveDirectoryArchivalToDatabase.psm1`.
- Do not split this into multiple modules. Add functions to that module and export them.
- SQL lives in `sql/`.
- Schema changes must be idempotent so `Initialize-ArchiveSchema.ps1` can be re-run.
- Logs go under the present working directory: `logs/log_{yyyy_MM_dd—HHmm_}{AM/PM}_UTC.log.txt`.

## Data flow

- On-prem and Entra are separate jobs.
- Each run truncates staging, loads it, then merges into the system-versioned table `ad.UserArchive`.
- SQL authentication is pass-through only. Do not add a SQL password, SQL login, or connection-string secret.
- Certificate validation stays on unless `AD_ARCHIVE_SQL_TRUST_SERVER_CERTIFICATE` is explicitly set.
- Archive every user object returned. Do not drop users because an extended attribute is unset.
- Never archive `unicodePwd`, `ntPwdHistory`, `dBCSPwd`, `supplementalCredentials`, or `msDS-ManagedPassword`.
- `InDaysOfInactivityBeforeDeleteQueue` is configuration only. Do not delete, disable, or queue-delete users.

## Secrets

Both jobs read one secret named by `AD_ARCHIVE_ENTRA_SECRET_ID`. AWS uses `AWS.Tools.SecretsManager` (`Get-SECSecretValue`) with `AWS_ACCESS_KEY` and `AWS_SECRET_KEY` passed as parameters. Azure Key Vault uses `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AD_ARCHIVE_AZURE_VAULT_NAME`.

The secret string must be this JSON. On-prem example values are placeholders on the reserved `example.com` domain. Replace them before use. Do not commit a real username or credential.

```json
{
  "ActiveDirectoryOnPrem": {
    "Username": "archive-reader@example.com",
    "Password": "example-only-replace-before-use"
  },
  "AzureGraphAPI": {
    "tenantId": "00000000-0000-0000-0000-000000000000",
    "clientId": "00000000-0000-0000-0000-000000000000",
    "clientSecret": "example-only-replace-before-use"
  },
  "Purpose": "For archival of Active Directory and entra",
  "InDaysOfInactivityBeforeDeleteQueue": 365
}
```

On-prem binds with `ActiveDirectoryOnPrem`. Graph uses only `AzureGraphAPI`. Do not log `Password` or `clientSecret`. Do not put a SQL password in this document.

## Audit and failure

- Every Active Directory and Microsoft Graph call writes `ad.DirectoryAudit` before the job continues.
- If the audit insert fails, stop. Do not continue the directory call.
- Permission failures stay in the audit table and the log so Active Directory administrators can grant read access. Do not elevate.
- Archive jobs call `Test-ArchivePrerequisites` first and fail closed.
- Wrap directory, SQL, and secret work in try/catch. Do not log attribute values, tokens, or secret contents.

## Build and signing

- `New-AdopterBuildPipeline.ps1` generates `.github/workflows/ci.yml` for the adopter's fork. Signing is optional and adopter-owned: `none` (default), `pfx`, `azure-key-vault`, or `ci-service`.
- The repo does not ship a signing certificate. Do not add one.
- `.gitleaks.toml` allowlists only the placeholder strings: `archive-reader@example.com`, `example-only-replace-before-use`, and the all-zero GUID. No whole-file path allowlists.
- `.github/signing/Invoke-AdopterSign.ps1` is a stub for the `ci-service` provider. Adopters replace it with their own signer.

## Do not

- Do not add user-deletion logic.
- Do not install RSAT or the AWS CLI unless the operator passed `-Install`.
- Do not commit `logs/`.
- Do not hardcode a domain name.
- Do not put a real credential in an example.
- Do not commit a PFX, password, or CA private key.
