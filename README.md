# PS-ActiveDirectoryArchivalToDatabase

Archive every on-premises Active Directory user, and separately every Microsoft Entra ID user, into SQL Server before any account is deleted.

This repository does not delete users. It only reads directory data and writes an archive. `InDaysOfInactivityBeforeDeleteQueue` is configuration only. It does not delete or disable accounts.

## What it stores

On-prem runs read the Active Directory schema (attribute name, LDAP syntax, and a mapped SQL data type) and store that definition as a versioned snapshot. A new schema version is written only when the captured attribute set changes.

Each user is archived even when extended attributes differ from user to user. Unset attributes are simply absent. Values that are present are stored two ways:

- A JSON document of every non-secret attribute returned for that user.
- Rows in a staging attribute table (name, syntax, SQL type, value) so the database keeps the data type, not only the text.

Secret-like attributes (`unicodePwd`, `ntPwdHistory`, `dBCSPwd`, `supplementalCredentials`, `msDS-ManagedPassword`) are never archived.

## Flow

1. `Initialize-ArchiveSchema.ps1` creates the `ad` schema, the schema-version tables, the staging tables, the run-statistics table, and a system-versioned archive table.
2. `Invoke-OnPremAdArchive.ps1` truncates staging, reads every user object, loads staging with pass-through (Windows integrated) authentication, then runs the ETL merge into `ad.UserArchive`.
3. `Invoke-EntraUserArchive.ps1` does the same for Entra ID users and profile properties. Directory credentials are read from the archive secret with `AWS.Tools.SecretsManager` or Azure Key Vault. They are not stored in the script. The AWS CLI is not used.

`ad.UserArchive` is a SQL Server temporal table. The merge updates a row only when the archived payload changed, so history is kept in `ad.UserArchiveHistory`.

Each directory call is also written to `ad.DirectoryAudit`: Active Directory schema read, Active Directory user read, Entra token request, and each Graph `/users` page. The row stores the run id, action, target, outcome (`Succeeded`, `Failed`, or `AccessDenied`), object count, duration, Windows identity, and host. Tokens and attribute values are not stored.

Each run records how many users were found, how many were saved, and how long the run took.

## Layout

Entry scripts live in the repo root. They import one module:

`module/PS-ActiveDirectoryArchivalToDatabase.psm1`

## Required machine configuration

Pass-through authentication is used for SQL Server. The account running the script needs `db_datareader`, `db_datawriter`, and `ALTER` on the archive tables (the initializer also needs `db_ddladmin` or equivalent).

| Variable | Required for | Purpose |
| --- | --- | --- |
| `AD_ARCHIVE_SQL_SERVER` | Every job | SQL Server instance |
| `AD_ARCHIVE_SQL_DATABASE` | Every job | Archive database |
| `AWS_ACCESS_KEY` | AWS provider | Access key passed to `Get-SECSecretValue` |
| `AWS_SECRET_KEY` | AWS provider | Secret key passed to `Get-SECSecretValue` |
| `AD_ARCHIVE_AWS_REGION` | AWS secret lookup | Region. Defaults to `us-east-1` |
| `AD_ARCHIVE_ENTRA_SECRET_ID` | Both jobs | Archive secret id or Key Vault secret name |

If `AWS_ACCESS_KEY` or `AWS_SECRET_KEY` is missing, the script stops with: these are required to allow secrets retrieval from AWS secrets management.

Both jobs read one secret. `-SecretProvider AWS` uses `AWS.Tools.SecretsManager`. `-SecretProvider Azure` uses Azure Key Vault. The secret string must already exist and must be this JSON:

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

| Field | Required | Format |
| --- | --- | --- |
| `ActiveDirectoryOnPrem.Username` | yes | On-prem bind account, `DOMAIN\\user` or `user@domain` |
| `ActiveDirectoryOnPrem.Password` | yes | Password for that bind account |
| `AzureGraphAPI.tenantId` | yes | Entra tenant GUID |
| `AzureGraphAPI.clientId` | yes | App registration client id GUID |
| `AzureGraphAPI.clientSecret` | yes | Client secret value, not the secret id |
| `Purpose` | yes | Short reason this secret exists |
| `InDaysOfInactivityBeforeDeleteQueue` | yes | Integer days. Configuration only. This job does not delete users. |

AWS uses `Get-SECSecretValue`. It does not use the AWS CLI. Keys are passed as cmdlet parameters and are not copied into `AWS_ACCESS_KEY_ID`.

Azure Key Vault requires `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AD_ARCHIVE_AZURE_VAULT_NAME`. If any are missing, the script stops with: these are required to allow secrets retrieval from Azure secrets management. The Key Vault identity needs get permission on that secret.

The Graph app registration needs application permission `User.Read.All` with admin consent. Do not put the SQL password or the vault reader secret in the stored JSON. SQL Server still uses pass-through authentication. Do not log `Password` or `clientSecret`.

On-prem reads need an account that can read user objects and the schema naming context. Access denied is logged as a permission failure so Active Directory administrators can grant read access. The script does not attempt to raise its own privileges.

## Logs

Every entry script writes a log under the present working directory:

`logs/log_{yyyy_MM_dd—HHmm_}{AM/PM}_UTC.log.txt`

Example: `logs/log_2026_10_02—1710_PM_UTC.log.txt`

Secrets, connection strings, and attribute values are not written to the log.

## Host prerequisites

The archive host is PowerShell 7 (`pwsh`) on a domain-joined Windows machine. The scripts require version 7.0 or later and do not install modules unless you pass `-Install`.

| Need | Used by | How to provide it |
| --- | --- | --- |
| ActiveDirectory module | On-prem job | RSAT: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` |
| AWS.Tools.SecretsManager | AWS provider | `Install-Module AWS.Tools.SecretsManager -Scope CurrentUser` |
| SqlClient | Every SQL call | PowerShell 7 needs `System.Data.SqlClient` or `Microsoft.Data.SqlClient`. `Install-Module SqlServer -Scope CurrentUser` if neither loads. |
| SQL environment variables | Every job | `AD_ARCHIVE_SQL_SERVER`, `AD_ARCHIVE_SQL_DATABASE` |
| AWS key environment variables | AWS provider | `AWS_ACCESS_KEY`, `AWS_SECRET_KEY` |

Check before a run:

```powershell
pwsh .\Test-ArchivePrerequisites.ps1 -Job All
pwsh .\Test-ArchivePrerequisites.ps1 -Job OnPrem -Install
pwsh .\Test-ArchivePrerequisites.ps1 -Job Entra -SecretProvider AWS -Install
```

`-Install` asks Windows to add RSAT and installs `AWS.Tools.SecretsManager` for the current user. It does not install the AWS CLI and it does not elevate itself. Active Directory read rights are separate from local admin rights and still have to be granted by the Active Directory administrators.

## Run

```powershell
pwsh .\Initialize-ArchiveSchema.ps1
pwsh .\Invoke-OnPremAdArchive.ps1
pwsh .\Invoke-EntraUserArchive.ps1 -SecretProvider AWS
pwsh .\Invoke-EntraUserArchive.ps1 -SecretProvider Azure
```

By default the on-prem job reads the domain the Windows account is already logged into. Pass `-Domain` with a domain DNS name, not a domain controller, when you are archiving another domain. The job discovers a writable controller, pins the schema read and the user read to that host, and writes the domain, responding controller, and site to `ad.DirectoryAudit` and the file log.

```powershell
pwsh .\Invoke-OnPremAdArchive.ps1 -Domain "glejeune.org"
```

`glejeune.org` is an example domain namespace. Replace it with the DNS name of the domain you are archiving. Omit `-Domain` for a normal run against the logon domain. This is not the SQL Server.

## Secret scanning

Secret scanning is a required build gate. `.github/workflows/ci.yml` runs gitleaks on the full git history on every push to `main` and every pull request. A finding fails the workflow. Secret values are redacted in the runner log.

`.gitleaks.toml` allowlists only these documentation placeholders: `archive-reader@example.com`, `example-only-replace-before-use`, and the all-zero GUID `00000000-0000-0000-0000-000000000000`. It does not allowlist whole files. A real credential in `README.md` or `AGENTS.md` fails the scan. A real credential that matches an allowlisted placeholder is a failed review.

Enable GitHub secret scanning and push protection on your fork. This repository does not store your secrets.

## Code signing

See [`.github/signing/README.md`](.github/signing/README.md) for all code signing documentation: the four signing modes, the `New-AdopterBuildPipeline.ps1` generator, the `code-signing` Actions environment, verification, and the HSM note.
