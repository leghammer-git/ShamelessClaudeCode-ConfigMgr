/*
  DotNetDependencyScan - can runtime major @RemoveMajor be uninstalled from each device?

  One row per device that has any runtime of that major installed:
    Safe to remove               nothing on the device currently runs on it, or every app
                                 that does will roll forward to another installed major
    Install newer runtime first  some apps allow a major roll-forward but no newer major of
                                 their framework/architecture is installed yet
    Blocked                      some apps' rollForward policy pins them to this major:
                                 vendor update (or a rollForward override) needed
    Scan incomplete / stale      not enough data to judge - see 04-ScanHealth.sql

  "Runs on it" uses ResolvedMajor - the runtime the app actually binds to today - rather
  than the version it asks for, so an app asking for 6.0 that runs on 8 counts against 8.
*/
DECLARE @RemoveMajor  int        = 8;
DECLARE @CollectionID varchar(8) = 'SMS00001';
DECLARE @MaxAgeDays   int        = 21;
DECLARE @Prefix       varchar(6) = CAST(@RemoveMajor AS varchar(5)) + '.';

;WITH Installed AS (
    SELECT r.ResourceID,
           STUFF((SELECT DISTINCT ', ' + REPLACE(r2.FrameworkName0, 'Microsoft.', '') + ' ' + r2.Version0 + ' ' + r2.Architecture0
                  FROM v_GS_DOTNET_RUNTIME0 r2
                  WHERE r2.ResourceID = r.ResourceID AND r2.Version0 LIKE @Prefix + '%'
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS Runtimes
    FROM v_GS_DOTNET_RUNTIME0 r
    JOIN v_FullCollectionMembership fcm ON fcm.ResourceID = r.ResourceID AND fcm.CollectionID = @CollectionID
    WHERE r.Version0 LIKE @Prefix + '%'
    GROUP BY r.ResourceID
),
Deps AS (
    SELECT d.ResourceID,
           SUM(CASE WHEN d.Verdict0 = 'Pinned'          THEN 1 ELSE 0 END) AS PinnedApps,
           SUM(CASE WHEN d.Verdict0 = 'NeedsNewerMajor' THEN 1 ELSE 0 END) AS NeedsNewerMajorApps,
           SUM(CASE WHEN d.Verdict0 = 'RollsForward'    THEN 1 ELSE 0 END) AS RollsForwardApps,
           STUFF((SELECT DISTINCT ', ' + d2.AppName0
                  FROM v_GS_DOTNET_APP_DEPENDENCY0 d2
                  WHERE d2.ResourceID = d.ResourceID AND d2.ResolvedMajor0 = @RemoveMajor
                    AND d2.Verdict0 IN ('Pinned', 'NeedsNewerMajor')
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS BlockingApps
    FROM v_GS_DOTNET_APP_DEPENDENCY0 d
    WHERE d.ResolvedMajor0 = @RemoveMajor
    GROUP BY d.ResourceID
)
SELECT s.Netbios_Name0 AS ComputerName,
       CASE
           WHEN st.ResourceID IS NULL                                  THEN 'Scan incomplete (no status)'
           WHEN DATEDIFF(DAY, st.ScanTime0, GETDATE()) > @MaxAgeDays   THEN 'Scan stale'
           WHEN st.Result0 <> 'Success'                                THEN 'Scan incomplete (' + st.Result0 + ')'
           WHEN ISNULL(dp.PinnedApps, 0) > 0                           THEN 'Blocked'
           WHEN ISNULL(dp.NeedsNewerMajorApps, 0) > 0                  THEN 'Install newer runtime first'
           ELSE 'Safe to remove'
       END                               AS Readiness,
       i.Runtimes                        AS InstalledRuntimesOfThisMajor,
       ISNULL(dp.PinnedApps, 0)          AS PinnedApps,
       ISNULL(dp.NeedsNewerMajorApps, 0) AS NeedsNewerMajorApps,
       ISNULL(dp.RollsForwardApps, 0)    AS RollsForwardApps,
       dp.BlockingApps,
       st.ScanTime0                      AS LastScan
FROM Installed i
JOIN v_R_System s ON s.ResourceID = i.ResourceID
LEFT JOIN v_GS_DOTNET_SCAN_STATUS0 st ON st.ResourceID = i.ResourceID
LEFT JOIN Deps dp ON dp.ResourceID = i.ResourceID
ORDER BY Readiness, ComputerName;
