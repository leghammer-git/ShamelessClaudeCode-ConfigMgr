/*
  DotNetDependencyScan - which applications stop runtime major @RemoveMajor being removed?

  Result 1: the vendor follow-up list. One row per app/version/policy, with how many
            devices it blocks and what has to happen:
              Pinned           rollForward (default Minor, or Disable/LatestPatch/LatestMinor)
                               keeps it on this major - needs a vendor update, or a
                               rollForward override you have tested
              NeedsNewerMajor  allows a major roll-forward; install the newer runtime of the
                               same framework and architecture, then remove this one
  Result 2: apps that find no installed runtime today (already broken, or the wrong
            architecture/framework is installed) - worth knowing before removing anything.
*/
DECLARE @RemoveMajor         int        = 8;
DECLARE @CollectionID        varchar(8) = 'SMS00001';
DECLARE @MaxAgeDays          int        = 21;
DECLARE @IncludeUserProfiles bit        = 1;   -- 0 = ignore apps found under C:\Users

SELECT ISNULL(NULLIF(d.Company0, ''), '(unknown)') AS Company,
       ISNULL(NULLIF(d.Product0, ''), '(unknown)') AS Product,
       d.AppName0                                 AS AppName,
       d.FrameworkName0                           AS Framework,
       d.HostArchitecture0                        AS Architecture,
       d.RequestedVersion0                        AS RequestedVersion,
       d.RollForward0                             AS RollForward,
       d.Verdict0                                 AS Verdict,
       CASE d.Verdict0
           WHEN 'Pinned'          THEN 'Vendor update, or a tested rollForward override'
           WHEN 'NeedsNewerMajor' THEN 'Install newer runtime, then remove'
       END                                        AS Action,
       COUNT(DISTINCT d.ResourceID)               AS Devices,
       MIN(d.ProductVersion0)                     AS LowestProductVersion,
       MAX(d.ProductVersion0)                     AS HighestProductVersion,
       MIN(d.AppFolder0)                          AS ExampleFolder
FROM v_GS_DOTNET_APP_DEPENDENCY0 d
JOIN v_FullCollectionMembership fcm ON fcm.ResourceID = d.ResourceID AND fcm.CollectionID = @CollectionID
WHERE d.ResolvedMajor0 = @RemoveMajor
  AND d.Verdict0 IN ('Pinned', 'NeedsNewerMajor')
  AND DATEDIFF(DAY, d.ScanTime0, GETDATE()) <= @MaxAgeDays
  AND (@IncludeUserProfiles = 1 OR d.InUserProfile0 = 0)
GROUP BY d.Company0, d.Product0, d.AppName0, d.FrameworkName0, d.HostArchitecture0,
         d.RequestedVersion0, d.RollForward0, d.Verdict0
ORDER BY Devices DESC, Company, AppName;

SELECT ISNULL(NULLIF(d.Company0, ''), '(unknown)') AS Company,
       d.AppName0                                 AS AppName,
       d.FrameworkName0                           AS Framework,
       d.HostArchitecture0                        AS Architecture,
       d.RequestedVersion0                        AS RequestedVersion,
       d.RollForward0                             AS RollForward,
       COUNT(DISTINCT d.ResourceID)               AS Devices,
       MIN(d.AppFolder0)                          AS ExampleFolder
FROM v_GS_DOTNET_APP_DEPENDENCY0 d
JOIN v_FullCollectionMembership fcm ON fcm.ResourceID = d.ResourceID AND fcm.CollectionID = @CollectionID
WHERE d.Verdict0 = 'Unresolved'
  AND DATEDIFF(DAY, d.ScanTime0, GETDATE()) <= @MaxAgeDays
  AND (@IncludeUserProfiles = 1 OR d.InUserProfile0 = 0)
GROUP BY d.Company0, d.AppName0, d.FrameworkName0, d.HostArchitecture0, d.RequestedVersion0, d.RollForward0
ORDER BY Devices DESC, Company, AppName;
