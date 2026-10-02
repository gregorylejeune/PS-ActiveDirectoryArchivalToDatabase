# PS-ActiveDirectoryArchivalToDatabase

Archive every on-premises Active Directory user, and separately every Microsoft Entra ID user, into SQL Server before any account is deleted.

This repository does not delete users. It only reads directory data and writes an archive.

## What it stores

On-prem runs read the Active Directory schema (attribute name, LDAP syntax, and a mapped SQL data type) and store that definition as a versioned snapshot. A new schema version is written only when the captured attribute set changes.

Each user is archived even when extended attributes differ from user to user. Unset attributes are simply absent. Values that are present are stored two ways:

- A JSON document of every non-secret attribute returned for that user.
- Rows in a staging attribute table (name, syntax, SQL type, value) so the database keeps the data type, not only the text.

Secret-like attributes (`unicodePwd`, `ntPwdHistory`, `dBCSPwd`, `supplementalCredentials`, `msDS-ManagedPassword`) are never archived.

## Flow

1. `Initialize-ArchiveSchema.ps1` creates the `ad` schema, the schema-version tables, the staging tables, the run-statistics table, and a system-versioned archive table.
2. `Invoke-OnPremAdArchive.ps1` truncates staging, reads every user object, loads staging with pass-through (Windows integrated) authentication, then runs the ETL merge into `ad.UserArchive`.
3. `Invoke-EntraUserArchive.ps1` does the same for Entra ID users and profile properties. Entra application credentials are read from AWS Secrets Manager. They are not stored in the script.

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
| `AWS_ACCESS_KEY` | Entra job, and any secret lookup | Access key for AWS Secrets Manager |
| `AWS_SECRET_KEY` | Entra job, and any secret lookup | Secret key for AWS Secrets Manager |
| `AD_ARCHIVE_AWS_REGION` | Secret lookup | Region. Defaults to `us-east-1` |
| `AD_ARCHIVE_ENTRA_SECRET_ID` | Entra job | Secrets Manager id or name |

If `AWS_ACCESS_KEY` or `AWS_SECRET_KEY` is missing, the script stops with: these are required to allow secrets retrieval from AWS secrets management.

The Entra secret JSON is expected to contain `tenantId`, `clientId`, and `clientSecret`. The app registration needs Microsoft Graph application permission `User.Read.All` (admin consent).

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
| AWS CLI v2 | Entra job | `winget install --id Amazon.AWSCLI -e` |
| SqlClient | Every SQL call | PowerShell 7 needs `System.Data.SqlClient` or `Microsoft.Data.SqlClient`. `Install-Module SqlServer -Scope CurrentUser` if neither loads. |
| SQL environment variables | Every job | `AD_ARCHIVE_SQL_SERVER`, `AD_ARCHIVE_SQL_DATABASE` |
| AWS key environment variables | Entra job | `AWS_ACCESS_KEY`, `AWS_SECRET_KEY` |

Check before a run:

```powershell
pwsh .\Test-ArchivePrerequisites.ps1 -Job All
pwsh .\Test-ArchivePrerequisites.ps1 -Job OnPrem -Install
```

`-Install` asks Windows to add RSAT and winget to add the AWS CLI. If the account is not a local administrator, the check logs the permission failure and stops. It does not elevate itself. Active Directory read rights are separate from local admin rights and still have to be granted by the Active Directory administrators.

## Run

```powershell
pwsh .\Initialize-ArchiveSchema.ps1
pwsh .\Invoke-OnPremAdArchive.ps1
pwsh .\Invoke-EntraUserArchive.ps1
```

Optional on-prem server override: `.\Invoke-OnPremAdArchive.ps1 -Server "dc01.contoso.local"`
