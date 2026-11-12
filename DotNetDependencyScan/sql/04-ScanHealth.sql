/*
  DotNetDependencyScan - is the data trustworthy?

  Every active client in the collection, with the state of its last scan:
    No data             baseline not deployed/evaluated yet, or the MOF classes are not
                        enabled in this device's client settings
    Stale               no scan in @MaxAgeDays (task not running? device offline?)
    Error               the scan failed - Message0 says why; full detail in
                        %WINDIR%\Logs\DotNetDependencyScan.log on the device
    TimeBudgetExceeded  the disk walk ran out of time; results are partial
    OK
  EnvRollForward is shown because a machine-wide DOTNET_ROLL_FORWARD changes every
  verdict on that device.
*/
DECLARE @CollectionID varchar(8) = 'SMS00001';
DECLARE @MaxAgeDays   int        = 14;

SELECT s.Netbios_Name0 AS ComputerName,
       CASE
           WHEN st.ResourceID IS NULL                                THEN 'No data'
           WHEN DATEDIFF(DAY, st.ScanTime0, GETDATE()) > @MaxAgeDays THEN 'Stale'
           WHEN st.Result0 <> 'Success'                              THEN st.Result0
           ELSE 'OK'
       END                  AS Health,
       st.ScanTime0         AS LastScan,
       st.DurationSeconds0  AS DurationSeconds,
       st.FilesFound0       AS FilesFound,
       st.DependencyCount0  AS Dependencies,
       st.ParseErrors0      AS ParseErrors,
       st.DirectoryErrors0  AS DirectoryErrors,
       st.DrivesScanned0    AS DrivesScanned,
       st.EnvRollForward0   AS EnvRollForward,
       st.ScannerVersion0   AS ScannerVersion,
       st.Message0          AS Message,
       ws.LastHWScan
FROM v_FullCollectionMembership fcm
JOIN v_R_System s ON s.ResourceID = fcm.ResourceID AND s.Client0 = 1 AND ISNULL(s.Obsolete0, 0) = 0
LEFT JOIN v_GS_DOTNET_SCAN_STATUS0 st ON st.ResourceID = s.ResourceID
LEFT JOIN v_GS_WORKSTATION_STATUS ws ON ws.ResourceID = s.ResourceID
WHERE fcm.CollectionID = @CollectionID
ORDER BY CASE WHEN st.ResourceID IS NULL THEN 0 ELSE 1 END, Health, ComputerName;
