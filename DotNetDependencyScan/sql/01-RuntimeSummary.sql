/*
  DotNetDependencyScan - installed .NET shared runtimes across the estate.

  Read from disk on each device (dotnet\shared\<framework>\<version>), not parsed from
  Add/Remove Programs names, so no dbo.fnSplitString is needed.

  Result 1: devices per framework / major version / architecture.
  Result 2: devices per exact version, to spot builds that are behind on patches.
*/
DECLARE @CollectionID varchar(8) = 'SMS00001';   -- limit to this collection
DECLARE @MaxAgeDays   int        = 21;           -- ignore inventory older than this

;WITH rt AS (
    SELECT r.ResourceID,
           r.FrameworkName0 AS FrameworkName,
           r.Version0       AS Version,
           r.Architecture0  AS Architecture,
           TRY_CAST(LEFT(r.Version0, CHARINDEX('.', r.Version0 + '.') - 1) AS int) AS Major
    FROM v_GS_DOTNET_RUNTIME0 r
    JOIN v_FullCollectionMembership fcm ON fcm.ResourceID = r.ResourceID AND fcm.CollectionID = @CollectionID
    WHERE DATEDIFF(DAY, r.ScanTime0, GETDATE()) <= @MaxAgeDays
)
SELECT FrameworkName, Major, Architecture, COUNT(DISTINCT ResourceID) AS Devices
FROM rt
GROUP BY FrameworkName, Major, Architecture
ORDER BY FrameworkName, Major DESC, Architecture;

;WITH rt AS (
    SELECT r.ResourceID, r.FrameworkName0 AS FrameworkName, r.Version0 AS Version, r.Architecture0 AS Architecture
    FROM v_GS_DOTNET_RUNTIME0 r
    JOIN v_FullCollectionMembership fcm ON fcm.ResourceID = r.ResourceID AND fcm.CollectionID = @CollectionID
    WHERE DATEDIFF(DAY, r.ScanTime0, GETDATE()) <= @MaxAgeDays
)
SELECT FrameworkName, Version, Architecture, COUNT(DISTINCT ResourceID) AS Devices
FROM rt
GROUP BY FrameworkName, Version, Architecture
ORDER BY FrameworkName, Architecture, Devices DESC;
