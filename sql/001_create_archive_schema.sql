/*
    Archive schema for on-prem Active Directory and Entra ID user snapshots.
    Staging is truncated on each run. The ETL merge writes into a system-versioned table.
    Pass-through (Windows integrated) authentication is required. No SQL password is stored here.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ad')
    EXEC(N'CREATE SCHEMA ad');
GO

IF OBJECT_ID(N'ad.SchemaVersion', N'U') IS NULL
BEGIN
    CREATE TABLE ad.SchemaVersion
    (
        SchemaVersionId     int             IDENTITY(1,1) NOT NULL CONSTRAINT PK_SchemaVersion PRIMARY KEY,
        SourceSystem        nvarchar(32)    NOT NULL,
        ContentHash         char(64)        NOT NULL,
        CapturedUtc         datetime2(3)    NOT NULL CONSTRAINT DF_SchemaVersion_CapturedUtc DEFAULT (SYSUTCDATETIME()),
        AttributeCount      int             NOT NULL,
        CONSTRAINT UQ_SchemaVersion_Source_Hash UNIQUE (SourceSystem, ContentHash)
    );
END
GO

IF OBJECT_ID(N'ad.AttributeDefinition', N'U') IS NULL
BEGIN
    CREATE TABLE ad.AttributeDefinition
    (
        AttributeDefinitionId   bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_AttributeDefinition PRIMARY KEY,
        SchemaVersionId         int             NOT NULL,
        SourceSystem            nvarchar(32)    NOT NULL,
        AttributeName           nvarchar(256)   NOT NULL,
        SyntaxOid               nvarchar(64)    NULL,
        AdSyntaxName            nvarchar(64)    NULL,
        SqlDataType             nvarchar(64)    NOT NULL,
        IsSingleValued          bit             NOT NULL CONSTRAINT DF_AttributeDefinition_IsSingleValued DEFAULT (1),
        CONSTRAINT FK_AttributeDefinition_SchemaVersion FOREIGN KEY (SchemaVersionId) REFERENCES ad.SchemaVersion (SchemaVersionId)
    );
    CREATE INDEX IX_AttributeDefinition_Version_Name ON ad.AttributeDefinition (SchemaVersionId, AttributeName);
END
GO

IF OBJECT_ID(N'ad.RunStatistic', N'U') IS NULL
BEGIN
    CREATE TABLE ad.RunStatistic
    (
        RunId               uniqueidentifier NOT NULL CONSTRAINT PK_RunStatistic PRIMARY KEY,
        SourceSystem        nvarchar(32)     NOT NULL,
        StartedUtc          datetime2(3)     NOT NULL,
        FinishedUtc         datetime2(3)     NULL,
        DurationMs          bigint           NULL,
        UsersFound          int              NOT NULL CONSTRAINT DF_RunStatistic_UsersFound DEFAULT (0),
        UsersSaved          int              NOT NULL CONSTRAINT DF_RunStatistic_UsersSaved DEFAULT (0),
        SchemaVersionId     int              NULL,
        Status              nvarchar(32)     NOT NULL,
        ErrorMessage        nvarchar(2000)   NULL
    );
END
GO

IF OBJECT_ID(N'ad.StagingUser', N'U') IS NULL
BEGIN
    CREATE TABLE ad.StagingUser
    (
        StagingUserId       bigint           IDENTITY(1,1) NOT NULL CONSTRAINT PK_StagingUser PRIMARY KEY,
        RunId               uniqueidentifier NOT NULL,
        SourceSystem        nvarchar(32)     NOT NULL,
        ObjectKey           nvarchar(64)     NOT NULL,
        SchemaVersionId     int              NOT NULL,
        SamAccountName      nvarchar(256)    NULL,
        UserPrincipalName   nvarchar(512)    NULL,
        DistinguishedName   nvarchar(1024)   NULL,
        DisplayName         nvarchar(512)    NULL,
        ProfileJson         nvarchar(max)    NOT NULL,
        AttributesJson      nvarchar(max)    NOT NULL,
        CONSTRAINT UQ_StagingUser_Run_Object UNIQUE (RunId, SourceSystem, ObjectKey)
    );
END
GO

IF OBJECT_ID(N'ad.StagingUserAttribute', N'U') IS NULL
BEGIN
    CREATE TABLE ad.StagingUserAttribute
    (
        StagingUserAttributeId  bigint           IDENTITY(1,1) NOT NULL CONSTRAINT PK_StagingUserAttribute PRIMARY KEY,
        RunId                   uniqueidentifier NOT NULL,
        SourceSystem            nvarchar(32)     NOT NULL,
        ObjectKey               nvarchar(64)     NOT NULL,
        AttributeName           nvarchar(256)    NOT NULL,
        SyntaxOid               nvarchar(64)     NULL,
        SqlDataType             nvarchar(64)     NOT NULL,
        AttributeValue          nvarchar(max)    NULL
    );
    CREATE INDEX IX_StagingUserAttribute_Run_Object ON ad.StagingUserAttribute (RunId, ObjectKey);
END
GO

IF OBJECT_ID(N'ad.UserArchive', N'U') IS NULL
BEGIN
    CREATE TABLE ad.UserArchive
    (
        UserArchiveId       bigint           IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserArchive PRIMARY KEY,
        SourceSystem        nvarchar(32)     NOT NULL,
        ObjectKey           nvarchar(64)     NOT NULL,
        SchemaVersionId     int              NOT NULL,
        SamAccountName      nvarchar(256)    NULL,
        UserPrincipalName   nvarchar(512)    NULL,
        DistinguishedName   nvarchar(1024)   NULL,
        DisplayName         nvarchar(512)    NULL,
        ProfileJson         nvarchar(max)    NOT NULL,
        AttributesJson      nvarchar(max)    NOT NULL,
        LastRunId           uniqueidentifier NOT NULL,
        ValidFrom           datetime2(3)     GENERATED ALWAYS AS ROW START NOT NULL,
        ValidTo             datetime2(3)     GENERATED ALWAYS AS ROW END NOT NULL,
        PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),
        CONSTRAINT UQ_UserArchive_Source_Object UNIQUE (SourceSystem, ObjectKey)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ad.UserArchiveHistory));
END
GO

CREATE OR ALTER PROCEDURE ad.usp_MergeStagingToArchive
    @RunId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    MERGE ad.UserArchive AS target
    USING (
        SELECT
            SourceSystem,
            ObjectKey,
            SchemaVersionId,
            SamAccountName,
            UserPrincipalName,
            DistinguishedName,
            DisplayName,
            ProfileJson,
            AttributesJson,
            RunId
        FROM ad.StagingUser
        WHERE RunId = @RunId
    ) AS source
    ON target.SourceSystem = source.SourceSystem
       AND target.ObjectKey = source.ObjectKey
    WHEN MATCHED AND (
        ISNULL(target.AttributesJson, N'') <> ISNULL(source.AttributesJson, N'')
        OR ISNULL(target.ProfileJson, N'') <> ISNULL(source.ProfileJson, N'')
        OR ISNULL(target.SamAccountName, N'') <> ISNULL(source.SamAccountName, N'')
        OR ISNULL(target.UserPrincipalName, N'') <> ISNULL(source.UserPrincipalName, N'')
        OR ISNULL(target.DistinguishedName, N'') <> ISNULL(source.DistinguishedName, N'')
        OR ISNULL(target.DisplayName, N'') <> ISNULL(source.DisplayName, N'')
        OR target.SchemaVersionId <> source.SchemaVersionId
    )
    THEN UPDATE SET
        SchemaVersionId = source.SchemaVersionId,
        SamAccountName = source.SamAccountName,
        UserPrincipalName = source.UserPrincipalName,
        DistinguishedName = source.DistinguishedName,
        DisplayName = source.DisplayName,
        ProfileJson = source.ProfileJson,
        AttributesJson = source.AttributesJson,
        LastRunId = source.RunId
    WHEN NOT MATCHED BY TARGET
    THEN INSERT (
        SourceSystem, ObjectKey, SchemaVersionId, SamAccountName, UserPrincipalName,
        DistinguishedName, DisplayName, ProfileJson, AttributesJson, LastRunId
    )
    VALUES (
        source.SourceSystem, source.ObjectKey, source.SchemaVersionId, source.SamAccountName, source.UserPrincipalName,
        source.DistinguishedName, source.DisplayName, source.ProfileJson, source.AttributesJson, source.RunId
    );

    SELECT @@ROWCOUNT AS RowsMerged;
END
GO
