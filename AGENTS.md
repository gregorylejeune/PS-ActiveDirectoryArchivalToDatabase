# Agent instructions

This repository archives users. It does not delete them, disable them, or change Active Directory or Entra ID.

## Host and layout

- Run with PowerShell 7 (`pwsh`). Scripts require 7.0 or later.
- Entry scripts stay in the repo root. They import one module: `module/PS-ActiveDirectoryArchivalToDatabase.psm1`.
- Do not split this into multiple modules. Add functions to that module and export them.
- SQL lives in `sql/`. Schema changes must be idempotent so `Initialize-ArchiveSchema.ps1` can be re-run.
- Logs go under the present working directory: `logs/log_{yyyy_MM_dd—HHmm_}{AM/PM}_UTC.log.txt`.

## Data flow

- On-prem and Entra are separate jobs.
- Each run truncates staging, loads it, then merges into the system-versioned table `ad.UserArchive`.
- SQL authentication is pass-through only. Do not add a SQL password, SQL login, or connection-string secret.
- Certificate validation stays on unless `AD_ARCHIVE_SQL_TRUST_SERVER_CERTIFICATE` is explicitly set.
- Archive every user object returned. Do not drop users because an extended attribute is unset.
- Never archive `unicodePwd`, `ntPwdHistory`, `dBCSPwd`, `supplementalCredentials`, or `msDS-ManagedPassword`.

## Secrets

`AWS_ACCESS_KEY` and `AWS_SECRET_KEY` are required before any AWS Secrets Manager call. If either is missing, stop with: these are required to allow secrets retrieval from AWS secrets management.

Clear any copied AWS process variables when the secret call finishes.

The Entra secret already exists. `AD_ARCHIVE_ENTRA_SECRET_ID` names it. The secret string must be JSON:

```json
{
  "tenantId": "00000000-0000-0000-0000-000000000000",
  "clientId": "00000000-0000-0000-0000-000000000000",
  "clientSecret": "the app registration client secret value"
}
```

Do not invent a different shape. Do not write secret values into the README, logs, audit table, or commits.

## Audit and failure

- Every Active Directory and Microsoft Graph call writes `ad.DirectoryAudit` before the job continues.
- If the audit insert fails, stop. Do not continue the directory call.
- Permission failures stay in the audit table and the log so Active Directory administrators can grant read access. Do not elevate.
- Archive jobs call `Test-ArchivePrerequisites` first and fail closed.
- Wrap directory, SQL, and secret work in try/catch. Do not log attribute values, tokens, or secret contents.

## Do not

- Do not add user-deletion logic.
- Do not install RSAT or the AWS CLI unless the operator passed `-Install`.
- Do not commit `logs/`.
