Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Shared functions for archiving on-prem Active Directory and Entra ID users into SQL Server.
.NOTES
    One module, many functions. Entry scripts in the repo root import this file from .\module.
    Secrets are never written to the log. SQL uses parameters. Directory passwords are not archived.
#>

$script:ExcludedAttributes = @(
    'unicodePwd',
    'ntPwdHistory',
    'dBCSPwd',
    'supplementalCredentials',
    'msDS-ManagedPassword',
    'msDS-ManagedPasswordId',
    'msDS-ManagedPasswordPreviousId'
)

$script:SyntaxMap = @{
    '2.5.5.1'  = @{ Name = 'DNString'; SqlType = 'nvarchar' }
    '2.5.5.2'  = @{ Name = 'OID'; SqlType = 'nvarchar' }
    '2.5.5.3'  = @{ Name = 'CaseSensitiveString'; SqlType = 'nvarchar' }
    '2.5.5.4'  = @{ Name = 'CaseIgnoreString'; SqlType = 'nvarchar' }
    '2.5.5.5'  = @{ Name = 'PrintableString'; SqlType = 'nvarchar' }
    '2.5.5.6'  = @{ Name = 'NumericString'; SqlType = 'nvarchar' }
    '2.5.5.7'  = @{ Name = 'DNBinary'; SqlType = 'nvarchar' }
    '2.5.5.8'  = @{ Name = 'Boolean'; SqlType = 'bit' }
    '2.5.5.9'  = @{ Name = 'Integer'; SqlType = 'int' }
    '2.5.5.10' = @{ Name = 'OctetString'; SqlType = 'varbinary' }
    '2.5.5.11' = @{ Name = 'UtcTime'; SqlType = 'datetime2' }
    '2.5.5.12' = @{ Name = 'UnicodeString'; SqlType = 'nvarchar' }
    '2.5.5.13' = @{ Name = 'PresentationAddress'; SqlType = 'nvarchar' }
    '2.5.5.14' = @{ Name = 'DNString'; SqlType = 'nvarchar' }
    '2.5.5.15' = @{ Name = 'NTSecurityDescriptor'; SqlType = 'nvarchar' }
    '2.5.5.16' = @{ Name = 'LargeInteger'; SqlType = 'bigint' }
    '2.5.5.17' = @{ Name = 'Sid'; SqlType = 'nvarchar' }
}

function Write-ArchiveLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        if (-not $script:ArchiveLogPath) {
            $script:ArchiveLogPath = New-ArchiveLogPath
        }
        $line = '{0:yyyy-MM-ddTHH:mm:ss.fffZ} [{1}] {2}' -f ([datetime]::UtcNow, $Level, $Message)
        Add-Content -LiteralPath $script:ArchiveLogPath -Value $line -Encoding utf8
        Write-Host $line
    }
    catch {
        Write-Warning "Archive log write failed: $($_.Exception.Message)"
    }
}

function New-ArchiveLogPath {
    [CmdletBinding()]
    param()
    try {
        $logDir = Join-Path -Path (Get-Location).Path -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $stamp = [datetime]::UtcNow
        $ampm = if ($stamp.Hour -ge 12) { 'PM' } else { 'AM' }
        $name = 'log_{0}—{1}_{2}_UTC.log.txt' -f $stamp.ToString('yyyy_MM_dd'), $stamp.ToString('HHmm'), $ampm
        return (Join-Path -Path $logDir -ChildPath $name)
    }
    catch {
        throw "Unable to create the log directory under the present working directory. $($_.Exception.Message)"
    }
}

function Assert-AwsSecretPrerequisites {
    [CmdletBinding()]
    param()
    try {
        $missing = @()
        if ([string]::IsNullOrWhiteSpace($env:AWS_ACCESS_KEY)) { $missing += 'AWS_ACCESS_KEY' }
        if ([string]::IsNullOrWhiteSpace($env:AWS_SECRET_KEY)) { $missing += 'AWS_SECRET_KEY' }
        if ($missing.Count -gt 0) {
            throw "AWS_ACCESS_KEY and AWS_SECRET_KEY are required to allow secrets retrieval from AWS secrets management. Missing: $($missing -join ', ')."
        }
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message $_.Exception.Message
        throw
    }
}

function Get-ArchiveSqlConnectionString {
    [CmdletBinding()]
    param()
    try {
        $server = $env:AD_ARCHIVE_SQL_SERVER
        $database = $env:AD_ARCHIVE_SQL_DATABASE
        if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($database)) {
            throw 'AD_ARCHIVE_SQL_SERVER and AD_ARCHIVE_SQL_DATABASE are required. SQL authentication is pass-through only; do not place a SQL password in the environment.'
        }
        return "Server=$server;Database=$database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Application Name=PS-ActiveDirectoryArchivalToDatabase;"
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message $_.Exception.Message
        throw
    }
}

function Invoke-ArchiveSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [switch]$NonQuery
    )
    try {
        $connectionString = Get-ArchiveSqlConnectionString
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()
        try {
            $command = $connection.CreateCommand()
            $command.CommandText = $Query
            $command.CommandTimeout = 0
            foreach ($key in $Parameters.Keys) {
                $value = $Parameters[$key]
                if ($null -eq $value) { $value = [DBNull]::Value }
                [void]$command.Parameters.AddWithValue("@$key", $value)
            }
            if ($NonQuery) {
                return $command.ExecuteNonQuery()
            }
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
            $table = New-Object System.Data.DataTable
            [void]$adapter.Fill($table)
            return $table
        }
        finally {
            $connection.Close()
        }
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "SQL command failed. $($_.Exception.Message)"
        throw
    }
}

function Initialize-ArchiveDatabase {
    [CmdletBinding()]
    param(
        [string]$SchemaFile = (Join-Path $PSScriptRoot '..\sql\001_create_archive_schema.sql')
    )
    try {
        Write-ArchiveLog -Message 'Initializing archive database schema with pass-through authentication.'
        if (-not (Test-Path -LiteralPath $SchemaFile)) {
            throw "Schema file not found: $SchemaFile"
        }
        $scriptText = Get-Content -LiteralPath $SchemaFile -Raw
        $batches = [regex]::Split($scriptText, '(?m)^\s*GO\s*$')
        foreach ($batch in $batches) {
            if (-not [string]::IsNullOrWhiteSpace($batch)) {
                [void](Invoke-ArchiveSql -Query $batch -NonQuery)
            }
        }
        Write-ArchiveLog -Message 'Archive schema initialization finished.'
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "Schema initialization failed. $($_.Exception.Message)"
        throw
    }
}

function Get-SqlTypeForSyntax {
    [CmdletBinding()]
    param([string]$SyntaxOid)
    if ($script:SyntaxMap.ContainsKey($SyntaxOid)) {
        return $script:SyntaxMap[$SyntaxOid]
    }
    return @{ Name = 'Unknown'; SqlType = 'nvarchar' }
}

function ConvertTo-ArchivePlainValue {
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [byte[]]) { return [Convert]::ToBase64String($Value) }
    if ($Value -is [System.Security.Principal.SecurityIdentifier]) { return $Value.Value }
    if ($Value -is [guid]) { return $Value.ToString() }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = foreach ($item in $Value) { ConvertTo-ArchivePlainValue -Value $item }
        return ($items -join ';')
    }
    return [string]$Value
}

function Get-OnPremSchemaAttributes {
    [CmdletBinding()]
    param([string]$Server)
    try {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            throw 'The ActiveDirectory PowerShell module is not installed. Request it from the Active Directory administrators or install RSAT Active Directory tools.'
        }
        Import-Module ActiveDirectory -ErrorAction Stop
        $root = if ($Server) { Get-ADRootDSE -Server $Server } else { Get-ADRootDSE }
        $params = @{
            SearchBase = $root.schemaNamingContext
            LDAPFilter = '(objectClass=attributeSchema)'
            Properties = @('lDAPDisplayName', 'attributeSyntax', 'isSingleValued', 'systemOnly')
        }
        if ($Server) { $params.Server = $Server }
        return @(Get-ADObject @params)
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'Access is denied|insufficient access|not authorized|Unauthorized|0x80072030|INSUFF_ACCESS_RIGHTS') {
            throw "Permission denied while reading the Active Directory schema. Request read permission on the schema naming context from the Active Directory administrators. $message"
        }
        throw
    }
}

function Save-SchemaVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceSystem,
        [Parameter(Mandatory)][object[]]$Attributes
    )
    try {
        $rows = foreach ($attribute in $Attributes) {
            $name = [string]$attribute.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $syntax = [string]$attribute.SyntaxOid
            $mapped = Get-SqlTypeForSyntax -SyntaxOid $syntax
            [pscustomobject]@{
                Name = $name
                SyntaxOid = $syntax
                SyntaxName = $mapped.Name
                SqlType = $mapped.SqlType
                IsSingleValued = [bool]$attribute.IsSingleValued
            }
        }
        $ordered = @($rows | Sort-Object Name -Unique)
        $hashSource = ($ordered | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Name, $_.SyntaxOid, $_.SqlType, $_.IsSingleValued }) -join "`n"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $contentHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashSource)))).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }

        $existing = Invoke-ArchiveSql -Query @'
SELECT SchemaVersionId
FROM ad.SchemaVersion
WHERE SourceSystem = @SourceSystem AND ContentHash = @ContentHash
'@ -Parameters @{ SourceSystem = $SourceSystem; ContentHash = $contentHash }

        if ($existing.Rows.Count -gt 0) {
            return [int]$existing.Rows[0].SchemaVersionId
        }

        $inserted = Invoke-ArchiveSql -Query @'
INSERT INTO ad.SchemaVersion (SourceSystem, ContentHash, AttributeCount)
OUTPUT INSERTED.SchemaVersionId
VALUES (@SourceSystem, @ContentHash, @AttributeCount)
'@ -Parameters @{ SourceSystem = $SourceSystem; ContentHash = $contentHash; AttributeCount = $ordered.Count }

        $versionId = [int]$inserted.Rows[0].SchemaVersionId
        foreach ($row in $ordered) {
            [void](Invoke-ArchiveSql -Query @'
INSERT INTO ad.AttributeDefinition
    (SchemaVersionId, SourceSystem, AttributeName, SyntaxOid, AdSyntaxName, SqlDataType, IsSingleValued)
VALUES
    (@SchemaVersionId, @SourceSystem, @AttributeName, @SyntaxOid, @AdSyntaxName, @SqlDataType, @IsSingleValued)
'@ -NonQuery -Parameters @{
                SchemaVersionId = $versionId
                SourceSystem = $SourceSystem
                AttributeName = $row.Name
                SyntaxOid = $row.SyntaxOid
                AdSyntaxName = $row.SyntaxName
                SqlDataType = $row.SqlType
                IsSingleValued = [int]$row.IsSingleValued
            })
        }
        Write-ArchiveLog -Message "Stored schema version $versionId for $SourceSystem ($($ordered.Count) attributes)."
        return $versionId
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "Schema version save failed. $($_.Exception.Message)"
        throw
    }
}

function Get-OnPremDirectoryUsers {
    [CmdletBinding()]
    param([string]$Server)
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $params = @{
            Filter = '*'
            Properties = '*'
            ResultPageSize = 500
        }
        if ($Server) { $params.Server = $Server }
        return @(Get-ADUser @params)
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'Access is denied|insufficient access|not authorized|Unauthorized|0x80072030|INSUFF_ACCESS_RIGHTS') {
            throw "Permission denied while reading Active Directory users. Request read access to user objects (Read all properties) from the Active Directory administrators. $message"
        }
        throw "Active Directory user read failed. $message"
    }
}

function Convert-DirectoryUserToArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$SourceSystem,
        [hashtable]$SyntaxByName = @{}
    )
    $properties = @{}
    $attributes = @()
    $propertyNames = @($User.PSObject.Properties.Name)
    if ($User.PSObject.Properties.Name -contains 'PropertyNames') {
        $propertyNames = @($User.PropertyNames)
    }
    foreach ($name in ($propertyNames | Sort-Object -Unique)) {
        if ($script:ExcludedAttributes -contains $name) { continue }
        if ($name -in @('PropertyNames', 'PropertyCount', 'AddedProperties', 'RemovedProperties', 'ModifiedProperties')) { continue }
        $raw = $User.$name
        if ($raw -is [System.Collections.IDictionary] -or $name -eq 'Keys') { continue }
        $plain = ConvertTo-ArchivePlainValue -Value $raw
        if ([string]::IsNullOrEmpty($plain)) { continue }
        $properties[$name] = $plain
        $syntax = $SyntaxByName[$name]
        $attributes += [pscustomobject]@{
            Name = $name
            Value = $plain
            SyntaxOid = $syntax.SyntaxOid
            SqlDataType = $(if ($syntax) { $syntax.SqlType } else { 'nvarchar' })
        }
    }
    $objectKey = if ($properties.ContainsKey('objectGUID')) { $properties['objectGUID'] } elseif ($properties.ContainsKey('id')) { $properties['id'] } else { [guid]::NewGuid().ToString() }
    [pscustomobject]@{
        SourceSystem = $SourceSystem
        ObjectKey = $objectKey
        SamAccountName = $properties['SamAccountName']
        UserPrincipalName = $properties['UserPrincipalName']
        DistinguishedName = $properties['DistinguishedName']
        DisplayName = $properties['DisplayName']
        Profile = $properties
        Attributes = $attributes
    }
}

function Clear-ArchiveStaging {
    [CmdletBinding()]
    param()
    try {
        Write-ArchiveLog -Message 'Truncating staging tables.'
        [void](Invoke-ArchiveSql -Query 'TRUNCATE TABLE ad.StagingUserAttribute; TRUNCATE TABLE ad.StagingUser;' -NonQuery)
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "Staging truncate failed. $($_.Exception.Message)"
        throw
    }
}

function Save-StagingUsers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][int]$SchemaVersionId,
        [Parameter(Mandatory)][object[]]$Users
    )
    try {
        $saved = 0
        foreach ($user in $Users) {
            $profileJson = $user.Profile | ConvertTo-Json -Depth 6 -Compress
            $attributesJson = $user.Attributes | ConvertTo-Json -Depth 4 -Compress
            [void](Invoke-ArchiveSql -Query @'
INSERT INTO ad.StagingUser
    (RunId, SourceSystem, ObjectKey, SchemaVersionId, SamAccountName, UserPrincipalName, DistinguishedName, DisplayName, ProfileJson, AttributesJson)
VALUES
    (@RunId, @SourceSystem, @ObjectKey, @SchemaVersionId, @SamAccountName, @UserPrincipalName, @DistinguishedName, @DisplayName, @ProfileJson, @AttributesJson)
'@ -NonQuery -Parameters @{
                RunId = $RunId.ToString()
                SourceSystem = $user.SourceSystem
                ObjectKey = $user.ObjectKey
                SchemaVersionId = $SchemaVersionId
                SamAccountName = $user.SamAccountName
                UserPrincipalName = $user.UserPrincipalName
                DistinguishedName = $user.DistinguishedName
                DisplayName = $user.DisplayName
                ProfileJson = $profileJson
                AttributesJson = $attributesJson
            })
            foreach ($attribute in $user.Attributes) {
                [void](Invoke-ArchiveSql -Query @'
INSERT INTO ad.StagingUserAttribute
    (RunId, SourceSystem, ObjectKey, AttributeName, SyntaxOid, SqlDataType, AttributeValue)
VALUES
    (@RunId, @SourceSystem, @ObjectKey, @AttributeName, @SyntaxOid, @SqlDataType, @AttributeValue)
'@ -NonQuery -Parameters @{
                    RunId = $RunId.ToString()
                    SourceSystem = $user.SourceSystem
                    ObjectKey = $user.ObjectKey
                    AttributeName = $attribute.Name
                    SyntaxOid = $attribute.SyntaxOid
                    SqlDataType = $attribute.SqlDataType
                    AttributeValue = $attribute.Value
                })
            }
            $saved++
        }
        return $saved
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "Staging save failed after $saved user(s). $($_.Exception.Message)"
        throw
    }
}

function Invoke-ArchiveEtl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$RunId)
    try {
        Write-ArchiveLog -Message "Merging staging run $RunId into the system-versioned archive."
        return Invoke-ArchiveSql -Query 'EXEC ad.usp_MergeStagingToArchive @RunId = @RunId' -Parameters @{ RunId = $RunId.ToString() }
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "ETL merge failed. $($_.Exception.Message)"
        throw
    }
}

function Write-RunStatistic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][string]$SourceSystem,
        [Parameter(Mandatory)][datetime]$StartedUtc,
        [datetime]$FinishedUtc = ([datetime]::UtcNow),
        [int]$UsersFound = 0,
        [int]$UsersSaved = 0,
        [int]$SchemaVersionId = 0,
        [Parameter(Mandatory)][string]$Status,
        [string]$ErrorMessage
    )
    try {
        $duration = [int64]($FinishedUtc.ToUniversalTime() - $StartedUtc.ToUniversalTime()).TotalMilliseconds
        $safeError = $ErrorMessage
        if ($safeError -and $safeError.Length -gt 2000) { $safeError = $safeError.Substring(0, 2000) }
        [void](Invoke-ArchiveSql -Query @'
MERGE ad.RunStatistic AS target
USING (SELECT @RunId AS RunId) AS source
ON target.RunId = source.RunId
WHEN MATCHED THEN UPDATE SET
    FinishedUtc = @FinishedUtc,
    DurationMs = @DurationMs,
    UsersFound = @UsersFound,
    UsersSaved = @UsersSaved,
    SchemaVersionId = NULLIF(@SchemaVersionId, 0),
    Status = @Status,
    ErrorMessage = @ErrorMessage
WHEN NOT MATCHED THEN INSERT
    (RunId, SourceSystem, StartedUtc, FinishedUtc, DurationMs, UsersFound, UsersSaved, SchemaVersionId, Status, ErrorMessage)
VALUES
    (@RunId, @SourceSystem, @StartedUtc, @FinishedUtc, @DurationMs, @UsersFound, @UsersSaved, NULLIF(@SchemaVersionId, 0), @Status, @ErrorMessage);
'@ -NonQuery -Parameters @{
            RunId = $RunId.ToString()
            SourceSystem = $SourceSystem
            StartedUtc = $StartedUtc.ToUniversalTime()
            FinishedUtc = $FinishedUtc.ToUniversalTime()
            DurationMs = $duration
            UsersFound = $UsersFound
            UsersSaved = $UsersSaved
            SchemaVersionId = $SchemaVersionId
            Status = $Status
            ErrorMessage = $safeError
        })
        Write-ArchiveLog -Message "Run $RunId ${Status}: found=$UsersFound saved=$UsersSaved durationMs=$duration"
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "Unable to write run statistics. $($_.Exception.Message)"
        throw
    }
}

function Get-AwsSecretString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SecretId)
    try {
        Assert-AwsSecretPrerequisites
        $env:AWS_ACCESS_KEY_ID = $env:AWS_ACCESS_KEY
        $env:AWS_SECRET_ACCESS_KEY = $env:AWS_SECRET_KEY
        $region = if ([string]::IsNullOrWhiteSpace($env:AD_ARCHIVE_AWS_REGION)) { 'us-east-1' } else { $env:AD_ARCHIVE_AWS_REGION }
        $aws = Get-Command aws -ErrorAction SilentlyContinue
        if (-not $aws) {
            throw 'The AWS CLI is required to retrieve secrets and was not found on PATH.'
        }
        $json = & aws secretsmanager get-secret-value --secret-id $SecretId --region $region --query SecretString --output text
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
            throw "AWS Secrets Manager did not return a secret for the configured secret id."
        }
        return $json
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message "Secret retrieval failed. $($_.Exception.Message)"
        throw
    }
}

function Get-EntraAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )
    try {
        $body = @{
            client_id = $ClientId
            client_secret = $ClientSecret
            scope = 'https://graph.microsoft.com/.default'
            grant_type = 'client_credentials'
        }
        $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'
        if ([string]::IsNullOrWhiteSpace($response.access_token)) {
            throw 'Entra token response did not contain an access token.'
        }
        return $response.access_token
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'unauthorized|insufficient privileges|Authorization_RequestDenied|403') {
            throw "Permission denied calling Microsoft Entra. Request admin consent for Microsoft Graph application permission User.Read.All. $message"
        }
        throw "Entra token request failed. $message"
    }
}

function Get-EntraDirectoryUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccessToken)
    try {
        $headers = @{ Authorization = "Bearer $AccessToken" }
        $uri = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,mail,givenName,surname,accountEnabled,jobTitle,department,companyName,officeLocation,mobilePhone,businessPhones,employeeId,createdDateTime,onPremisesSamAccountName,onPremisesDistinguishedName,onPremisesDomainName,onPremisesImmutableId,onPremisesSyncEnabled&$expand=extensions'
        $users = @()
        while ($uri) {
            $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
            $users += @($page.value)
            $uri = $page.'@odata.nextLink'
        }
        return $users
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'Authorization_RequestDenied|Insufficient privileges|403|accessDenied') {
            throw "Permission denied while reading Entra users. Request Microsoft Graph application permission User.Read.All with admin consent. $message"
        }
        throw "Entra user read failed. $message"
    }
}

function Invoke-OnPremArchive {
    [CmdletBinding()]
    param([string]$Server)
    $runId = [guid]::NewGuid()
    $started = [datetime]::UtcNow
    $found = 0
    $saved = 0
    $schemaVersionId = 0
    try {
        Write-ArchiveLog -Message "Starting on-prem Active Directory archive run $runId."
        $schema = @(Get-OnPremSchemaAttributes -Server $Server | ForEach-Object {
            [pscustomobject]@{
                Name = $_.lDAPDisplayName
                SyntaxOid = [string]$_.attributeSyntax
                IsSingleValued = [bool]$_.isSingleValued
            }
        })
        $schemaVersionId = Save-SchemaVersion -SourceSystem 'OnPrem' -Attributes $schema
        $syntaxByName = @{}
        foreach ($item in $schema) {
            $mapped = Get-SqlTypeForSyntax -SyntaxOid $item.SyntaxOid
            $syntaxByName[$item.Name] = @{ SyntaxOid = $item.SyntaxOid; SqlType = $mapped.SqlType }
        }
        Clear-ArchiveStaging
        $directoryUsers = @(Get-OnPremDirectoryUsers -Server $Server)
        $found = $directoryUsers.Count
        Write-ArchiveLog -Message "Found $found on-prem user object(s)."
        $archiveUsers = foreach ($directoryUser in $directoryUsers) {
            Convert-DirectoryUserToArchive -User $directoryUser -SourceSystem 'OnPrem' -SyntaxByName $syntaxByName
        }
        $saved = Save-StagingUsers -RunId $runId -SchemaVersionId $schemaVersionId -Users @($archiveUsers)
        [void](Invoke-ArchiveEtl -RunId $runId)
        Write-RunStatistic -RunId $runId -SourceSystem 'OnPrem' -StartedUtc $started -UsersFound $found -UsersSaved $saved -SchemaVersionId $schemaVersionId -Status 'Succeeded'
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message $_.Exception.Message
        try {
            Write-RunStatistic -RunId $runId -SourceSystem 'OnPrem' -StartedUtc $started -UsersFound $found -UsersSaved $saved -SchemaVersionId $schemaVersionId -Status 'Failed' -ErrorMessage $_.Exception.Message
        }
        catch {
            Write-ArchiveLog -Level ERROR -Message "Run statistic fallback failed. $($_.Exception.Message)"
        }
        throw
    }
}

function Invoke-EntraArchive {
    [CmdletBinding()]
    param()
    $runId = [guid]::NewGuid()
    $started = [datetime]::UtcNow
    $found = 0
    $saved = 0
    $schemaVersionId = 0
    try {
        Write-ArchiveLog -Message "Starting Entra ID archive run $runId."
        Assert-AwsSecretPrerequisites
        $secretId = $env:AD_ARCHIVE_ENTRA_SECRET_ID
        if ([string]::IsNullOrWhiteSpace($secretId)) {
            throw 'AD_ARCHIVE_ENTRA_SECRET_ID is required and must name the AWS Secrets Manager secret that holds tenantId, clientId, and clientSecret.'
        }
        $secret = Get-AwsSecretString -SecretId $secretId | ConvertFrom-Json
        foreach ($required in @('tenantId', 'clientId', 'clientSecret')) {
            if ([string]::IsNullOrWhiteSpace($secret.$required)) {
                throw "The AWS secret is missing '$required'."
            }
        }
        $token = Get-EntraAccessToken -TenantId $secret.tenantId -ClientId $secret.clientId -ClientSecret $secret.clientSecret
        $sampleNames = @(
            'id','displayName','userPrincipalName','mail','givenName','surname','accountEnabled','jobTitle','department',
            'companyName','officeLocation','mobilePhone','businessPhones','employeeId','createdDateTime',
            'onPremisesSamAccountName','onPremisesDistinguishedName','onPremisesDomainName','onPremisesImmutableId','onPremisesSyncEnabled'
        )
        $schema = foreach ($name in $sampleNames) {
            [pscustomobject]@{ Name = $name; SyntaxOid = '2.5.5.12'; IsSingleValued = $true }
        }
        $schemaVersionId = Save-SchemaVersion -SourceSystem 'Entra' -Attributes $schema
        Clear-ArchiveStaging
        $directoryUsers = @(Get-EntraDirectoryUsers -AccessToken $token)
        $found = $directoryUsers.Count
        Write-ArchiveLog -Message "Found $found Entra user(s)."
        $archiveUsers = foreach ($directoryUser in $directoryUsers) {
            $wrapped = [pscustomobject]$directoryUser
            Convert-DirectoryUserToArchive -User $wrapped -SourceSystem 'Entra'
        }
        $saved = Save-StagingUsers -RunId $runId -SchemaVersionId $schemaVersionId -Users @($archiveUsers)
        [void](Invoke-ArchiveEtl -RunId $runId)
        Write-RunStatistic -RunId $runId -SourceSystem 'Entra' -StartedUtc $started -UsersFound $found -UsersSaved $saved -SchemaVersionId $schemaVersionId -Status 'Succeeded'
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message $_.Exception.Message
        try {
            Write-RunStatistic -RunId $runId -SourceSystem 'Entra' -StartedUtc $started -UsersFound $found -UsersSaved $saved -SchemaVersionId $schemaVersionId -Status 'Failed' -ErrorMessage $_.Exception.Message
        }
        catch {
            Write-ArchiveLog -Level ERROR -Message "Run statistic fallback failed. $($_.Exception.Message)"
        }
        throw
    }
}

function Test-ArchivePrerequisites {
    [CmdletBinding()]
    param(
        [ValidateSet('OnPrem', 'Entra', 'Schema', 'All')]
        [string]$Job = 'All',
        [switch]$Install
    )
    try {
        $checks = @()
        $needOnPrem = $Job -in @('OnPrem', 'All')
        $needEntra = $Job -in @('Entra', 'All')
        $needSql = $true

        $checks += [pscustomobject]@{
            Name = 'Windows PowerShell 5.1 host'
            Ready = ($PSVersionTable.PSEdition -eq 'Desktop' -or $PSVersionTable.PSVersion.Major -eq 5)
            Detail = "Edition=$($PSVersionTable.PSEdition) Version=$($PSVersionTable.PSVersion)"
        }

        $sqlClient = [bool]([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Data' })
        if (-not $sqlClient) {
            try {
                Add-Type -AssemblyName System.Data
                $sqlClient = $true
            }
            catch { $sqlClient = $false }
        }
        $checks += [pscustomobject]@{
            Name = 'System.Data.SqlClient'
            Ready = $sqlClient
            Detail = 'Built into Windows PowerShell. Required for pass-through SQL connections.'
        }

        if ($needOnPrem) {
            $adModule = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
            $checks += [pscustomobject]@{
                Name = 'ActiveDirectory module'
                Ready = $adModule
                Detail = 'RSAT Active Directory Domain Services tools. Required to read users and the schema naming context.'
            }
            if (-not $adModule -and $Install) {
                Write-ArchiveLog -Message 'Attempting to install RSAT Active Directory tools. This requires a local administrator.'
                try {
                    $capability = Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools*' | Select-Object -First 1
                    if ($capability -and $capability.State -ne 'Installed') {
                        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
                    }
                    $checks[-1].Ready = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
                }
                catch {
                    Write-ArchiveLog -Level ERROR -Message "Could not install the ActiveDirectory module. Request local administrator rights, or ask the Active Directory administrators to install RSAT on this host. $($_.Exception.Message)"
                }
            }
        }

        if ($needEntra) {
            $aws = [bool](Get-Command aws -ErrorAction SilentlyContinue)
            $checks += [pscustomobject]@{
                Name = 'AWS CLI'
                Ready = $aws
                Detail = 'Required to read the Entra app secret from AWS Secrets Manager.'
            }
            if (-not $aws -and $Install) {
                Write-ArchiveLog -Message 'Attempting to install the AWS CLI with winget. This may require a local administrator.'
                try {
                    $winget = Get-Command winget -ErrorAction SilentlyContinue
                    if (-not $winget) { throw 'winget is not available on this host.' }
                    & winget install --id Amazon.AWSCLI -e --accept-package-agreements --accept-source-agreements
                    $checks[-1].Ready = [bool](Get-Command aws -ErrorAction SilentlyContinue)
                }
                catch {
                    Write-ArchiveLog -Level ERROR -Message "Could not install the AWS CLI. Request local administrator rights or install AWS CLI v2 manually. $($_.Exception.Message)"
                }
            }
            $awsKeys = -not [string]::IsNullOrWhiteSpace($env:AWS_ACCESS_KEY) -and -not [string]::IsNullOrWhiteSpace($env:AWS_SECRET_KEY)
            $checks += [pscustomobject]@{
                Name = 'AWS_ACCESS_KEY and AWS_SECRET_KEY'
                Ready = $awsKeys
                Detail = 'These are required to allow secrets retrieval from AWS secrets management.'
            }
            $checks += [pscustomobject]@{
                Name = 'AD_ARCHIVE_ENTRA_SECRET_ID'
                Ready = -not [string]::IsNullOrWhiteSpace($env:AD_ARCHIVE_ENTRA_SECRET_ID)
                Detail = 'Secrets Manager id for tenantId, clientId, and clientSecret.'
            }
        }

        if ($needSql) {
            $checks += [pscustomobject]@{
                Name = 'AD_ARCHIVE_SQL_SERVER'
                Ready = -not [string]::IsNullOrWhiteSpace($env:AD_ARCHIVE_SQL_SERVER)
                Detail = 'SQL Server instance for pass-through authentication.'
            }
            $checks += [pscustomobject]@{
                Name = 'AD_ARCHIVE_SQL_DATABASE'
                Ready = -not [string]::IsNullOrWhiteSpace($env:AD_ARCHIVE_SQL_DATABASE)
                Detail = 'Archive database name.'
            }
        }

        foreach ($check in $checks) {
            $level = if ($check.Ready) { 'INFO' } else { 'ERROR' }
            Write-ArchiveLog -Level $level -Message ("Prerequisite [{0}] {1}. {2}" -f $(if ($check.Ready) { 'ready' } else { 'missing' }), $check.Name, $check.Detail)
        }
        $missing = @($checks | Where-Object { -not $_.Ready })
        if ($missing.Count -gt 0) {
            throw ("Archive prerequisites are missing: {0}. Do not run the archive job until these are present. Install is not automatic unless -Install is passed, and install still fails closed when this account is not a local administrator." -f ($missing.Name -join ', '))
        }
        return $checks
    }
    catch {
        Write-ArchiveLog -Level ERROR -Message $_.Exception.Message
        throw
    }
}

Export-ModuleMember -Function @(
    'Test-ArchivePrerequisites',
    'Write-ArchiveLog',
    'Assert-AwsSecretPrerequisites',
    'Initialize-ArchiveDatabase',
    'Invoke-OnPremArchive',
    'Invoke-EntraArchive'
)
