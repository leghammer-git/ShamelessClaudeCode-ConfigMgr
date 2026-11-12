<#
.SYNOPSIS
    DotNetDependencyScan - inventories the .NET (Core / 5+) runtime dependencies of
    applications on this device and records them in WMI for ConfigMgr hardware inventory.

.DESCRIPTION
    Finds every <app>.runtimeconfig.json on the local fixed drives, works out which shared
    framework (Microsoft.NETCore.App, Microsoft.WindowsDesktop.App, Microsoft.AspNetCore.App)
    each app asks for, and emulates the .NET host's roll-forward rules against the runtimes
    installed on this device to answer two questions:
      - which runtime does this app run on today?
      - would it still start if that runtime's major version were uninstalled?

    Results are written to three WMI classes in root\cimv2:
      CM_DotNetAppDependency   one instance per app per framework reference
      CM_DotNetRuntime         one instance per installed shared runtime
      CM_DotNetScanStatus      one instance describing the last scan, so a device with no
                               dependencies can be told apart from one that never scanned

    Apart from its log and WMI, this script changes nothing on the device and makes no
    network connections. It is installed and scheduled (weekly, as SYSTEM) by the
    DotNetDependencyScan ConfigMgr configuration item - see README.md.

    Based on the concept published by Sherry Kissinger, TCSMUG,
    "dotNet Dependencies Reporting via ConfigMgr" (2026).

.PARAMETER Drives
    Drive roots to scan, e.g. 'C:\','D:\'. Defaults to all local fixed drives.

.PARAMETER ExcludePath
    Folders to skip. Entries starting with '\' are relative to every drive root;
    anything else is treated as a full path.

.PARAMETER TimeBudgetMinutes
    Stop walking the disk after this many minutes and record Result = TimeBudgetExceeded.

.PARAMETER LogPath
    CMTrace-format log. Defaults to %WINDIR%\Logs\DotNetDependencyScan.log.

.PARAMETER NoWmi
    Scan and return the dependency records as objects without touching WMI (for testing).

.EXAMPLE
    .\Invoke-DotNetDependencyScan.ps1 -Verbose

.EXAMPLE
    .\Invoke-DotNetDependencyScan.ps1 -NoWmi -Drives 'C:\' |
        Format-Table AppName, FrameworkName, RequestedVersion, RollForward, ResolvedVersion, Verdict
#>
[CmdletBinding()]
param(
    [string[]]$Drives,
    [string[]]$ExcludePath = @(
        '\Windows\WinSxS', '\Windows\Installer', '\Windows\servicing', '\Windows\SoftwareDistribution',
        '\Windows\ccmcache', '\Windows\Temp', '\$Recycle.Bin', '\System Volume Information'
    ),
    [ValidateRange(1, 1440)][int]$TimeBudgetMinutes = 60,
    [string]$LogPath,
    [switch]$NoWmi
)

$ScannerVersion = '2.0.0'

#region Logging

function Initialize-ScanLog {
    param([string]$Path, [int]$MaxKB = 1024)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and $item.Length -ge ($MaxKB * 1KB)) {
            Move-Item -LiteralPath $Path -Destination ([IO.Path]::ChangeExtension($Path, '.lo_')) -Force
        }
    } catch { }
}

function Write-ScanLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info',
        [string]$Component = 'Scanner'
    )
    Write-Verbose $Message
    if (-not $LogPath) { return }
    $now = Get-Date
    $bias = -[TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $line = '<![LOG[{0}]LOG]!><time="{1}{2:+0;-0;+0}" date="{3}" component="{4}" context="" type="{5}" thread="{6}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'), $Component,
        @{ Info = 1; Warning = 2; Error = 3 }[$Severity], $PID
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

#endregion

#region runtimeconfig.json parsing and roll-forward emulation (no side effects; covered by tests)

function ConvertTo-ComparableVersion {
    param([AllowNull()][AllowEmptyString()][string]$Version)
    if ($Version -match '^\s*(\d+)\.(\d+)(?:\.(\d+))?') {
        $patch = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        return [version]::new([int]$Matches[1], [int]$Matches[2], $patch)
    }
    $null
}

function ConvertTo-RollForwardPolicy {
    param($Value)
    if ($null -eq $Value) { return $null }
    # -eq is case-insensitive, so this also returns the canonical casing.
    'Disable', 'LatestPatch', 'Minor', 'LatestMinor', 'Major', 'LatestMajor' |
        Where-Object { $_ -eq [string]$Value } | Select-Object -First 1
}

function ConvertFrom-LegacyRollForward {
    # Pre-.NET Core 3.0 settings: rollForwardOnNoCandidateFx 0/1/2 plus applyPatches.
    param($OnNoCandidateFx, $ApplyPatches)
    if ($null -eq $OnNoCandidateFx) { return $null }
    switch ([int]$OnNoCandidateFx) {
        0 { if ($ApplyPatches -eq $false) { 'Disable' } else { 'LatestPatch' } }
        2 { 'Major' }
        default { 'Minor' }
    }
}

function New-DependencyRecord {
    param([string]$Path, [string]$AppName, [string]$AppFolder)
    [pscustomobject][ordered]@{
        ConfigPath             = $Path
        FrameworkName          = ''
        AppName                = $AppName
        AppFolder              = $AppFolder
        RequestedVersion       = ''
        RequestedMajor         = 0
        Tfm                    = ''
        RollForward            = ''
        AllowsMajorRollForward = $false
        SelfContained          = $false
        ResolvedVersion        = ''
        ResolvedMajor          = 0
        FallbackVersion        = ''
        Verdict                = ''
        HostFile               = ''
        HostArchitecture       = ''
        Company                = ''
        Product                = ''
        ProductVersion         = ''
        InUserProfile          = $false
        ScanTime               = $null
        ParseError             = ''
    }
}

function Get-RuntimeConfigInfo {
    <#
        Returns one record per framework reference in a runtimeconfig.json, or a single
        record with ParseError set if the file can't be read. Returns nothing if the file
        has no framework references at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$EnvRollForward
    )
    # Split on either separator so this also works when tested on non-Windows hosts.
    $sep = $Path.LastIndexOfAny([char[]]@('\', '/'))
    $folder = if ($sep -ge 0) { $Path.Substring(0, $sep) } else { '' }
    $appName = $Path.Substring($sep + 1) -replace '(?i)\.runtimeconfig\.json$', ''

    try {
        $json = $Content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $record = New-DependencyRecord $Path $appName $folder
        $record.ParseError = $_.Exception.Message
        return $record
    }
    $options = $json.runtimeOptions
    if ($null -eq $options) {
        $record = New-DependencyRecord $Path $appName $folder
        $record.ParseError = 'No runtimeOptions section'
        return $record
    }

    $appPolicy = ConvertTo-RollForwardPolicy $options.rollForward
    if (-not $appPolicy) { $appPolicy = ConvertFrom-LegacyRollForward $options.rollForwardOnNoCandidateFx $options.applyPatches }

    # includedFrameworks = self-contained: the app carries its own runtime.
    $selfContained = $null -ne $options.includedFrameworks
    $references = if ($selfContained) { @($options.includedFrameworks) }
                  else { @($options.framework) + @($options.frameworks) }

    foreach ($ref in $references) {
        if ($null -eq $ref) { continue }
        $record = New-DependencyRecord $Path $appName $folder
        $record.FrameworkName = [string]$ref.name
        $record.RequestedVersion = [string]$ref.version
        $record.Tfm = [string]$options.tfm
        $record.SelfContained = $selfContained
        $requested = ConvertTo-ComparableVersion $record.RequestedVersion
        if ($requested) { $record.RequestedMajor = $requested.Major }

        if (-not $selfContained) {
            # Precedence: framework reference, then app-wide, then machine DOTNET_ROLL_FORWARD
            # (applied only where the app sets nothing), then the host default of Minor.
            $policy = ConvertTo-RollForwardPolicy $ref.rollForward
            if (-not $policy) { $policy = ConvertFrom-LegacyRollForward $ref.rollForwardOnNoCandidateFx $ref.applyPatches }
            if (-not $policy) { $policy = $appPolicy }
            if (-not $policy) { $policy = ConvertTo-RollForwardPolicy $EnvRollForward }
            if (-not $policy) { $policy = 'Minor' }
            $record.RollForward = $policy
            $record.AllowsMajorRollForward = $policy -in 'Major', 'LatestMajor'
        }
        $record
    }
}

function Get-VersionBand {
    # The candidates sharing major.minor with the lowest (or highest) candidate.
    param([object[]]$Set, [switch]$Highest)
    if (-not $Set) { return }
    $edge = $Set | Sort-Object { $_.Version } -Descending:$Highest | Select-Object -First 1
    $Set | Where-Object { $_.Version.Major -eq $edge.Version.Major -and $_.Version.Minor -eq $edge.Version.Minor }
}

function Select-FrameworkVersion {
    <#
        Emulates hostfxr framework resolution: given the requested version, the rollForward
        policy and the installed versions of that framework, returns the version the app
        would run on, or $null. -ExcludeMajor answers "what if this major were removed?".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestedVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RollForward,
        [string[]]$Available,
        [int]$ExcludeMajor = -1
    )
    $requested = ConvertTo-ComparableVersion $RequestedVersion
    if (-not $requested) { return $null }
    # Prerelease runtimes are only considered when the app itself asks for a prerelease.
    $allowPrerelease = $RequestedVersion.Contains('-')

    $candidates = @(foreach ($text in $Available) {
        if (-not $allowPrerelease -and $text.Contains('-')) { continue }
        $version = ConvertTo-ComparableVersion $text
        if ($version -and $version -ge $requested -and $version.Major -ne $ExcludeMajor) {
            [pscustomobject]@{ Text = $text; Version = $version }
        }
    })
    if ($candidates.Count -eq 0) { return $null }
    $sameMajor = @($candidates | Where-Object { $_.Version.Major -eq $requested.Major })

    # Every candidate is >= the requested version, so the lowest band of $candidates is the
    # same-major band when one exists, otherwise the next higher major.
    $pool = switch ($RollForward) {
        'Disable'     { $candidates | Where-Object { $_.Version -eq $requested } }
        'LatestPatch' { $sameMajor | Where-Object { $_.Version.Minor -eq $requested.Minor } }
        'Minor'       { Get-VersionBand $sameMajor }
        'LatestMinor' { Get-VersionBand $sameMajor -Highest }
        'Major'       { Get-VersionBand $candidates }
        'LatestMajor' { Get-VersionBand $candidates -Highest }
    }
    # Within the chosen major.minor the host always takes the latest patch.
    $pool | Sort-Object { $_.Version } -Descending | Select-Object -First 1 | ForEach-Object { $_.Text }
}

function Resolve-FrameworkDependency {
    <#
        Fills in ResolvedVersion, ResolvedMajor, FallbackVersion and Verdict on a record:
          SelfContained    ships its own runtime; installed runtimes don't matter
          Unresolved       no installed runtime satisfies it today
          RollsForward     still starts if ResolvedMajor is removed (on FallbackVersion)
          NeedsNewerMajor  blocks removal of ResolvedMajor until a newer major is installed
          Pinned           blocks removal of ResolvedMajor; rollForward forbids a major change
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Dependency,
        [object[]]$InstalledRuntime,
        [Parameter(Mandatory)][string]$Architecture
    )
    if ($Dependency.SelfContained) { $Dependency.Verdict = 'SelfContained'; return }

    $available = @($InstalledRuntime | Where-Object {
            $_.FrameworkName -eq $Dependency.FrameworkName -and $_.Architecture -eq $Architecture
        } | ForEach-Object { $_.Version })
    $resolved = Select-FrameworkVersion -RequestedVersion $Dependency.RequestedVersion -RollForward $Dependency.RollForward -Available $available
    if (-not $resolved) { $Dependency.Verdict = 'Unresolved'; return }

    $Dependency.ResolvedVersion = $resolved
    $Dependency.ResolvedMajor = (ConvertTo-ComparableVersion $resolved).Major
    $fallback = Select-FrameworkVersion -RequestedVersion $Dependency.RequestedVersion -RollForward $Dependency.RollForward -Available $available -ExcludeMajor $Dependency.ResolvedMajor
    if ($fallback) {
        $Dependency.FallbackVersion = $fallback
        $Dependency.Verdict = 'RollsForward'
    } elseif ($Dependency.AllowsMajorRollForward) {
        $Dependency.Verdict = 'NeedsNewerMajor'
    } else {
        $Dependency.Verdict = 'Pinned'
    }
}

#endregion

#region Device discovery

function Get-NativeArchitecture {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
}

function Get-InstalledDotNetRuntime {
    # Reads <dotnet root>\shared\<framework>\<version> directly, rather than relying on
    # Add/Remove Programs names, so xcopy and Visual Studio-installed runtimes are included.
    param([Parameter(Mandatory)][string]$NativeArchitecture)

    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $roots = New-Object System.Collections.Generic.List[object]
    foreach ($arch in 'x64', 'x86', 'arm64') {
        foreach ($view in 'SOFTWARE\WOW6432Node', 'SOFTWARE') {
            $key = "HKLM:\$view\dotnet\Setup\InstalledVersions\$arch"
            $location = (Get-ItemProperty -LiteralPath $key -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
            if ($location) { $roots.Add([pscustomobject]@{ Architecture = $arch; Path = $location.TrimEnd('\') }) }
        }
    }
    $roots.Add([pscustomobject]@{ Architecture = $NativeArchitecture; Path = "$programFiles\dotnet" })
    if ($NativeArchitecture -ne 'x86' -and ${env:ProgramFiles(x86)}) {
        $roots.Add([pscustomobject]@{ Architecture = 'x86'; Path = "${env:ProgramFiles(x86)}\dotnet" })
    }
    if ($NativeArchitecture -eq 'arm64') {
        $roots.Add([pscustomobject]@{ Architecture = 'x64'; Path = "$programFiles\dotnet\x64" })
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $roots) {
        if (-not $seen.Add("$($root.Architecture)|$($root.Path)")) { continue }
        $shared = Join-Path $root.Path 'shared'
        if (-not [IO.Directory]::Exists($shared)) { continue }
        foreach ($frameworkDir in [IO.Directory]::GetDirectories($shared)) {
            $frameworkName = [IO.Path]::GetFileName($frameworkDir)
            foreach ($versionDir in [IO.Directory]::GetDirectories($frameworkDir)) {
                $version = [IO.Path]::GetFileName($versionDir)
                # The host ignores version folders without <framework>.deps.json (uninstall leftovers).
                if (-not (ConvertTo-ComparableVersion $version)) { continue }
                if (-not [IO.File]::Exists((Join-Path $versionDir "$frameworkName.deps.json"))) { continue }
                [pscustomobject]@{
                    FrameworkName = $frameworkName
                    Version       = $version
                    Architecture  = $root.Architecture
                    Path          = $versionDir
                    ScanTime      = $null
                }
            }
        }
    }
}

function Find-RuntimeConfigFile {
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [string[]]$ExcludePath,
        [Parameter(Mandatory)][TimeSpan]$TimeBudget,
        [Parameter(Mandatory)][hashtable]$Stats
    )
    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in $Root) {
        foreach ($path in $ExcludePath) {
            if ($path.StartsWith('\')) { [void]$excluded.Add($drive.TrimEnd('\') + $path.TrimEnd('\')) }
            else { [void]$excluded.Add($path.TrimEnd('\')) }
        }
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    foreach ($drive in $Root) { $pending.Push($drive) }
    while ($pending.Count -gt 0) {
        if ($clock.Elapsed -gt $TimeBudget) {
            $Stats.TimedOut = $true
            $Stats.Unscanned = $pending.Count
            break
        }
        $directory = New-Object System.IO.DirectoryInfo ($pending.Pop())
        try {
            foreach ($file in $directory.EnumerateFiles('*.runtimeconfig.json')) {
                if ($file.Name.EndsWith('.runtimeconfig.json', [StringComparison]::OrdinalIgnoreCase)) { $file.FullName }
            }
            foreach ($child in $directory.EnumerateDirectories()) {
                # Skip junctions and symlinks so nothing is visited twice or loops.
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($excluded.Contains($child.FullName)) { continue }
                $pending.Push($child.FullName)
            }
        } catch {
            $Stats.DirectoryErrors++
        }
    }
}

function Get-PEArchitecture {
    # Reads the machine type from a PE header, e.g. to tell an x86 apphost from an x64 one.
    param([string]$Path)
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.BinaryReader ($stream)
            if ($reader.ReadUInt16() -ne 0x5A4D) { return '' }
            $stream.Position = 0x3C
            $stream.Position = $reader.ReadInt32()
            if ($reader.ReadUInt32() -ne 0x00004550) { return '' }
            switch ([int]$reader.ReadUInt16()) { 0x014C { 'x86' } 0x8664 { 'x64' } 0xAA64 { 'arm64' } default { '' } }
        } finally { $stream.Dispose() }
    } catch { '' }
}

function Get-HostFileInfo {
    param([string]$Folder, [string]$AppName)
    $info = [pscustomobject]@{ HostFile = ''; Architecture = ''; Company = ''; Product = ''; ProductVersion = '' }
    $exe = Join-Path $Folder "$AppName.exe"
    $dll = Join-Path $Folder "$AppName.dll"
    $hasExe = [IO.File]::Exists($exe)
    $hasDll = [IO.File]::Exists($dll)
    if ($hasExe) {
        $info.HostFile = $exe
        $info.Architecture = Get-PEArchitecture $exe
    } elseif ($hasDll) {
        $info.HostFile = $dll
    }
    $versionSource = if ($hasDll) { $dll } elseif ($hasExe) { $exe }
    if ($versionSource) {
        try {
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($versionSource)
            $info.Company = "$($version.CompanyName)".Trim()
            $info.Product = "$($version.ProductName)".Trim()
            $info.ProductVersion = "$($version.ProductVersion)".Trim()
        } catch { }
    }
    $info
}

#endregion

#region WMI

function ConvertTo-WmiValue {
    param($Value, [string]$Type)
    if ($null -eq $Value) { return $null }
    switch ($Type) {
        'DateTime' { [System.Management.ManagementDateTimeConverter]::ToDmtfDateTime([datetime]$Value) }
        'UInt32'   { [uint32]$Value }
        'Boolean'  { [bool]$Value }
        default    { [string]$Value }
    }
}

function Set-WmiClass {
    # Creates the class, or recreates it if an earlier scanner version left a different schema.
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ClassName,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Schema,
        [Parameter(Mandatory)][string[]]$Key
    )
    $wanted = @(foreach ($name in $Schema.Keys) { '{0}:{1}:{2}' -f $name, $Schema[$name], ($Key -contains $name) }) | Sort-Object
    $existing = $null
    try { $existing = Get-CimClass -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop } catch { }
    if ($existing) {
        $current = @(foreach ($p in $existing.CimClassProperties) { '{0}:{1}:{2}' -f $p.Name, $p.CimType, [bool]$p.Qualifiers['Key'] }) | Sort-Object
        if (($current -join ';') -eq ($wanted -join ';')) { return }
        Write-ScanLog "WMI class $ClassName has a different schema; recreating it." -Severity Warning
        ([wmiclass]('\\.\{0}:{1}' -f $Namespace, $ClassName)).Delete()
    }
    Write-ScanLog "Creating WMI class $Namespace\$ClassName"
    $class = New-Object System.Management.ManagementClass ($Namespace, [string]::Empty, $null)
    $class['__CLASS'] = $ClassName
    $class.Qualifiers.Add('Static', $true)
    foreach ($name in $Schema.Keys) {
        $class.Properties.Add($name, [System.Management.CimType]$Schema[$name], $false)
        if ($Key -contains $name) { $class.Properties[$name].Qualifiers.Add('Key', $true) }
    }
    [void]$class.Put()
}

function Write-WmiInstance {
    # Upserts one instance per input object. With -RemoveUnlisted, also deletes instances
    # that weren't written this time, so the class mirrors the latest complete scan.
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ClassName,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Schema,
        [Parameter(Mandatory)][string[]]$Key,
        [object[]]$InputObject,
        [switch]$RemoveUnlisted
    )
    $class = New-Object System.Management.ManagementClass ('\\.\{0}:{1}' -f $Namespace, $ClassName)
    $written = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($object in $InputObject) {
        $instance = $class.CreateInstance()
        foreach ($name in $Schema.Keys) {
            $value = ConvertTo-WmiValue $object.$name $Schema[$name]
            if ($null -ne $value) { $instance[$name] = $value.psobject.BaseObject }
        }
        [void]$instance.Put()
        [void]$written.Add((($Key | ForEach-Object { [string]$object.$_ }) -join '|'))
    }
    if ($RemoveUnlisted) {
        foreach ($existing in @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName)) {
            $id = ($Key | ForEach-Object { [string]$existing.$_ }) -join '|'
            if (-not $written.Contains($id)) { Remove-CimInstance -InputObject $existing }
        }
    }
}

#endregion

# Dot-sourcing (e.g. from the Pester tests) loads the functions above without scanning.
if ($MyInvocation.InvocationName -eq '.') { return }

#region Main

$ErrorActionPreference = 'Stop'
$WmiNamespace = 'root\cimv2'
$DependencySchema = [ordered]@{
    ConfigPath = 'String'; FrameworkName = 'String'; AppName = 'String'; AppFolder = 'String'
    RequestedVersion = 'String'; RequestedMajor = 'UInt32'; Tfm = 'String'; RollForward = 'String'
    AllowsMajorRollForward = 'Boolean'; SelfContained = 'Boolean'
    ResolvedVersion = 'String'; ResolvedMajor = 'UInt32'; FallbackVersion = 'String'; Verdict = 'String'
    HostFile = 'String'; HostArchitecture = 'String'; Company = 'String'; Product = 'String'; ProductVersion = 'String'
    InUserProfile = 'Boolean'; ScanTime = 'DateTime'
}
$RuntimeSchema = [ordered]@{
    FrameworkName = 'String'; Version = 'String'; Architecture = 'String'; Path = 'String'; ScanTime = 'DateTime'
}
$StatusSchema = [ordered]@{
    Id = 'String'; ScanTime = 'DateTime'; DurationSeconds = 'UInt32'; Result = 'String'; Message = 'String'
    FilesFound = 'UInt32'; DependencyCount = 'UInt32'; ParseErrors = 'UInt32'; DirectoryErrors = 'UInt32'
    DrivesScanned = 'String'; EnvRollForward = 'String'; ScannerVersion = 'String'
}

if (-not $LogPath) { $LogPath = Join-Path $env:WINDIR 'Logs\DotNetDependencyScan.log' }
Initialize-ScanLog $LogPath
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

$scanStart = Get-Date
$stats = @{ DirectoryErrors = 0; TimedOut = $false; Unscanned = 0 }
$result = 'Success'
$message = ''
$files = @()
$dependencies = @()
$parseErrors = 0
$envRollForward = ''

Write-ScanLog "***** DotNetDependencyScan $ScannerVersion starting *****"
try {
    if (-not $Drives) {
        $Drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' })
    }
    $envRollForward = "$([Environment]::GetEnvironmentVariable('DOTNET_ROLL_FORWARD', 'Machine'))"
    if ($envRollForward) { Write-ScanLog "Machine-wide DOTNET_ROLL_FORWARD=$envRollForward (applied to apps that set no rollForward)" -Severity Warning }

    $nativeArch = Get-NativeArchitecture
    $runtimes = @(Get-InstalledDotNetRuntime -NativeArchitecture $nativeArch)
    foreach ($runtime in $runtimes) { $runtime.ScanTime = $scanStart }
    Write-ScanLog ("Installed shared runtimes ({0}): {1}" -f $runtimes.Count,
        (($runtimes | ForEach-Object { "$($_.FrameworkName) $($_.Version) $($_.Architecture)" }) -join ', '))

    $profileRoot = "$env:SystemDrive\Users"
    try {
        $profileRoot = [Environment]::ExpandEnvironmentVariables(
            (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory).ProfilesDirectory)
    } catch { }

    Write-ScanLog "Searching $($Drives -join ', ') for *.runtimeconfig.json (time budget $TimeBudgetMinutes min)"
    $files = @(Find-RuntimeConfigFile -Root $Drives -ExcludePath $ExcludePath -TimeBudget ([TimeSpan]::FromMinutes($TimeBudgetMinutes)) -Stats $stats)
    Write-ScanLog "Found $($files.Count) runtimeconfig.json files; $($stats.DirectoryErrors) directories could not be read"

    $dependencies = @(foreach ($file in $files) {
        try {
            $content = [IO.File]::ReadAllText($file)
        } catch {
            $parseErrors++
            Write-ScanLog "Could not read ${file}: $($_.Exception.Message)" -Severity Warning
            continue
        }
        $records = @(Get-RuntimeConfigInfo -Path $file -Content $content -EnvRollForward $envRollForward)
        if ($records.Count -eq 0) {
            Write-ScanLog "No framework reference in $file"
            continue
        }
        if ($records[0].ParseError) {
            $parseErrors++
            Write-ScanLog "Could not parse ${file}: $($records[0].ParseError)" -Severity Warning
            continue
        }
        $hostInfo = Get-HostFileInfo -Folder $records[0].AppFolder -AppName $records[0].AppName
        $arch = if ($hostInfo.Architecture) { $hostInfo.Architecture } else { $nativeArch }
        foreach ($record in $records) {
            $record.HostFile = $hostInfo.HostFile
            $record.HostArchitecture = $hostInfo.Architecture
            $record.Company = $hostInfo.Company
            $record.Product = $hostInfo.Product
            $record.ProductVersion = $hostInfo.ProductVersion
            $record.InUserProfile = $file.StartsWith($profileRoot + '\', [StringComparison]::OrdinalIgnoreCase)
            $record.ScanTime = $scanStart
            Resolve-FrameworkDependency -Dependency $record -InstalledRuntime $runtimes -Architecture $arch
            Write-ScanLog ("{0} | {1} {2} | rollForward={3} | {4} resolved={5} fallback={6}" -f $file, $record.FrameworkName,
                $record.RequestedVersion, $record.RollForward, $record.Verdict, $record.ResolvedVersion, $record.FallbackVersion)
            $record
        }
    })

    if ($stats.TimedOut) {
        $result = 'TimeBudgetExceeded'
        $message = "Stopped after $TimeBudgetMinutes minutes with $($stats.Unscanned) directories still queued; results are partial."
        Write-ScanLog $message -Severity Warning
    }

    if (-not $NoWmi) {
        Set-WmiClass -Namespace $WmiNamespace -ClassName 'CM_DotNetRuntime' -Schema $RuntimeSchema -Key FrameworkName, Version, Architecture
        Write-WmiInstance -Namespace $WmiNamespace -ClassName 'CM_DotNetRuntime' -Schema $RuntimeSchema -Key FrameworkName, Version, Architecture -InputObject $runtimes -RemoveUnlisted
        Set-WmiClass -Namespace $WmiNamespace -ClassName 'CM_DotNetAppDependency' -Schema $DependencySchema -Key ConfigPath, FrameworkName
        # A partial scan updates what it found but keeps rows it didn't get to.
        Write-WmiInstance -Namespace $WmiNamespace -ClassName 'CM_DotNetAppDependency' -Schema $DependencySchema -Key ConfigPath, FrameworkName -InputObject $dependencies -RemoveUnlisted:(-not $stats.TimedOut)
        Write-ScanLog "Wrote $($runtimes.Count) runtimes and $($dependencies.Count) dependencies to $WmiNamespace"
    }
} catch {
    $result = 'Error'
    $message = $_.Exception.Message
    Write-ScanLog "Scan failed: $message" -Severity Error
}

if ($NoWmi) {
    Write-ScanLog "***** DotNetDependencyScan finished ($result), -NoWmi: nothing written *****"
    return $dependencies
}

$status = [pscustomobject]@{
    Id              = 'Last'
    ScanTime        = $scanStart
    DurationSeconds = [uint32]((Get-Date) - $scanStart).TotalSeconds
    Result          = $result
    Message         = $message
    FilesFound      = $files.Count
    DependencyCount = $dependencies.Count
    ParseErrors     = $parseErrors
    DirectoryErrors = $stats.DirectoryErrors
    DrivesScanned   = ($Drives -join ';')
    EnvRollForward  = $envRollForward
    ScannerVersion  = $ScannerVersion
}
try {
    Set-WmiClass -Namespace $WmiNamespace -ClassName 'CM_DotNetScanStatus' -Schema $StatusSchema -Key Id
    Write-WmiInstance -Namespace $WmiNamespace -ClassName 'CM_DotNetScanStatus' -Schema $StatusSchema -Key Id -InputObject $status -RemoveUnlisted
} catch {
    $result = 'Error'
    Write-ScanLog "Could not write scan status: $($_.Exception.Message)" -Severity Error
}

Write-ScanLog "***** DotNetDependencyScan finished: $result in $($status.DurationSeconds)s *****"
if ($result -eq 'Error') { exit 1 }
exit 0

#endregion
