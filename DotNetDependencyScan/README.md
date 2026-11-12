# DotNetDependencyScan

Find out which applications depend on a .NET runtime major version, and whether they still start once that version is uninstalled. The data reaches ConfigMgr through hardware inventory.

This builds on Sherry Kissinger's TCSMUG post [dotNet Dependencies Reporting via ConfigMgr](https://tcsmug.org/blogs/sherry-kissinger/602-dotnet-dependencies-reporting-via-configmgr) (2026). The original download is kept unchanged in `../DotNetDependencies/`.

.NET 8 and .NET 9 reached end of support on 10 November 2026.

## What changed from the original

| Original | This version |
|---|---|
| Self-contained apps (`includedFrameworks`) were reported as needing the installed runtime | Flagged `SelfContained` and excluded from removal decisions |
| `rollForward` ignored, so you couldn't tell whether an "8.0.0" app runs on 10 | The scanner emulates the .NET host's roll-forward rules against the runtimes on the device. It reports what each app runs on today and what it falls back to if that major is removed (`Verdict`) |
| Framework name not stored; only the first version kept when an app references several | One row per app per framework: NETCore, WindowsDesktop and AspNetCore are separate installs |
| App name cut at the first dot (`Citrix.EngineUI.App` became `Citrix`) | Full name, plus the vendor's Company, Product and ProductVersion from the app's binary, and the apphost's CPU architecture |
| Full scan of C: inside the CI, at risk of the 60 s CI script timeout | The CI only installs and checks a weekly scheduled task, which does the scan. All fixed drives are scanned, with junctions and system folders skipped and a time budget |
| A device with no dependencies looked the same as a device that never ran | `CM_DotNetScanStatus` records every scan: result, duration, counts, errors |
| Installed runtimes parsed from Add/Remove Programs names with `dbo.fnSplitString` | `CM_DotNetRuntime` reads `dotnet\shared\<framework>\<version>` from disk, for each architecture |
| Log rotation never ran (it checked `$LogFilePath` but set `$LogFullPath`) | Fixed: rotates to `.lo_` at 1 MB |

## How it works

```
 ConfigMgr baseline (daily)                 Scheduled task (weekly, SYSTEM)
 ┌──────────────────────────┐   installs    ┌─────────────────────────────────────┐
 │ Discovery   (read-only)  │──────────────▶│ Invoke-DotNetDependencyScan.ps1     │
 │ Remediation (idempotent) │   & repairs   │  walks fixed drives for             │
 └──────────────────────────┘               │  *.runtimeconfig.json, resolves     │
                                            │  each against installed runtimes    │
                                            └──────────────┬──────────────────────┘
                                                           ▼
                                  root\cimv2: CM_DotNetAppDependency
                                              CM_DotNetRuntime
                                              CM_DotNetScanStatus
                                                           │  hardware inventory
                                                           ▼
                               v_GS_DOTNET_APP_DEPENDENCY0 / _RUNTIME0 / _SCAN_STATUS0
                                                           │
                                                           ▼
                                                     sql/*.sql reports
```

## Files

| Path | What it is |
|---|---|
| `ci/Discovery.ps1` | Paste into the CI as the **discovery** script |
| `ci/Remediation.ps1` | Paste into the CI as the **remediation** script. It embeds the full scanner as plain text |
| `ci/Uninstall.ps1` | Removes the task, files, WMI classes and registry key |
| `DotNetDependencyScan.mof` | Hardware inventory classes to import |
| `sql/01-RuntimeSummary.sql` | Installed runtimes by framework, major and architecture |
| `sql/02-RemovalReadiness.sql` | For each device: can major N be removed? |
| `sql/03-BlockingApps.sql` | The vendor follow-up list, plus apps that are already broken |
| `sql/04-ScanHealth.sql` | Devices with no data, stale data or failed scans |
| `src/Invoke-DotNetDependencyScan.ps1` | The scanner source. This is the file to edit |
| `templates/*.template.ps1` | Sources for the two CI scripts |
| `Build-CIScripts.ps1` | Regenerates `ci/Discovery.ps1` and `ci/Remediation.ps1` |
| `tests/Scanner.Tests.ps1` | Pester tests for parsing and roll-forward logic |

## Setup

### 1. (Optional) Change the defaults and rebuild

The scripts in `ci/` are already built with these defaults:

| Setting | Default |
|---|---|
| Schedule | Wednesday 12:00 with up to 4 h random delay |
| Execution policy | `RemoteSigned` |
| Time budget | 60 min |
| Results count as stale after | 10 days |

To change any of these, edit and rebuild. Run the build on any Windows machine with Windows PowerShell 5.1:

```powershell
.\Build-CIScripts.ps1 -ScheduleDay Sunday -ScheduleTime 03:00 -RandomDelayHours 6
```

Rebuild every time you change `src/` or `templates/`, then re-paste **both** scripts into the CI. The build stamps a matching hash and task signature into both, so they must be updated together. On devices that already have the old version, discovery reports `ScannerChanged` or `TaskOutdated` and remediation updates them.

### 2. Create the configuration item

**Assets and Compliance › Compliance Settings › Configuration Items › Create Configuration Item**

1. **General:** set the name to `DotNet Dependency Scan`. Leave the type as *Windows Desktops and Servers (custom)*.
2. **Supported Platforms:** all Windows versions you manage.
3. **Settings › New:**
   - Name: `ScannerHealth`. Setting type: **Script**. Data type: **String**.
   - Discovery script: **Add Script…**, language **Windows PowerShell**, then paste `ci/Discovery.ps1`.
   - Remediation script: **Add Script…**, language **Windows PowerShell**, then paste `ci/Remediation.ps1`.
   - Leave **Run scripts by using the logged on user credentials** and **Use 32-bit scripting host on 64-bit devices** unticked.
4. **Compliance Rules › New:**
   - Rule type **Value**. The value returned by the specified script **Equals** `Compliant`.
   - Tick **Run the specified remediation script when this setting is noncompliant**.
   - Tick **Report noncompliance if this setting instance is not found**.
   - Severity: *Information* or *Warning*, as you prefer.

### 3. Create and deploy the baseline

**Configuration Baselines › Create Configuration Baseline**: add the CI.

**Deploy** it to a test collection first:

- Tick **Remediate noncompliant rules when supported**.
- Tick **Allow remediation outside the maintenance window** if you want. Remediation only writes a script and registers a task; the scan itself runs from the task.
- Schedule: **daily**. Discovery is cheap (under 2 s). The disk scan happens weekly through the task, whatever the baseline schedule is.

Compliance reports show the discovery output, so a noncompliant device shows *why*, for example `NonCompliant: TaskMissing;NeverScanned`:

| Reason | Fixed automatically? |
|---|---|
| `ScannerMissing`, `ScannerChanged`, `TaskMissing`, `TaskDisabled`, `TaskOutdated`, `NeverScanned`, `ScanStale`, `ScanFromOldVersion` | Yes, by remediation |
| `LastScanError`, `LastScanTimeBudgetExceeded` | No. Read `%WINDIR%\Logs\DotNetDependencyScan.log` on the device. These are deliberately not retried daily; the weekly run retries them |

### 4. Add the hardware inventory classes

**Administration › Client Settings › Default Client Settings › Properties › Hardware Inventory › Set Classes… › Import…**: choose `DotNetDependencyScan.mof`, then **Import both hardware inventory classes and hardware inventory class settings**.

Watch `dataldr.log` on the primary site server for the new tables and views. The view names should be `v_GS_DOTNET_APP_DEPENDENCY0`, `v_GS_DOTNET_RUNTIME0` and `v_GS_DOTNET_SCAN_STATUS0`. Confirm them with:

```sql
SELECT name FROM sys.views WHERE name LIKE 'v_GS_DOTNET%';
```

If you previously deployed the original solution, its `CM_dotnetDependencies` class and `v_GS_DOTNETDEPENDENCIES0` view are separate and unaffected. Retire the old baseline when you're ready; `ci/Uninstall.ps1` can also remove the old WMI class (set `$RemoveLegacy = $true`).

### 5. Verify on a test device

1. Run **Machine Policy Retrieval** on the test device, then **Evaluate** the baseline in the Configuration Manager control panel.
   - The first evaluation reports noncompliant (`ScannerMissing;TaskMissing;NeverScanned`).
   - Remediation installs the scanner and starts a scan.
   - The re-check reports Compliant, because the task is running.
2. Check the log, `%WINDIR%\Logs\DotNetDependencyScan.log`. It is in CMTrace format, with components `Remediation` and `Scanner`.
3. When the scan finishes, check the results:
   ```powershell
   Get-CimInstance root\cimv2 -ClassName CM_DotNetScanStatus
   Get-CimInstance root\cimv2 -ClassName CM_DotNetAppDependency |
       Format-Table AppName, FrameworkName, RequestedVersion, RollForward, ResolvedVersion, FallbackVersion, Verdict
   ```
4. Run **Hardware Inventory Cycle** and look for the `CM_DotNet*` classes in `InventoryAgent.log`.
5. Run `sql/04-ScanHealth.sql`, then the other reports.

To try the scanner on one machine without ConfigMgr or WMI, run this from an elevated prompt:

```powershell
.\src\Invoke-DotNetDependencyScan.ps1 -NoWmi -Verbose |
    Format-Table AppName, FrameworkName, RequestedVersion, RollForward, ResolvedVersion, Verdict
```

## Reading the results

Each app × framework row carries a **Verdict**. It answers: *"if the runtime major this app runs on today were uninstalled, would it still start?"*

| Verdict | Meaning | What to do |
|---|---|---|
| `RollsForward` | Another installed major satisfies it (`FallbackVersion`) | Nothing. Check `FallbackVersion` isn't another runtime you're also removing |
| `NeedsNewerMajor` | Its `rollForward` is `Major`/`LatestMajor`, but no newer major of that framework and architecture is installed | Deploy the newer runtime, then remove the old one |
| `Pinned` | Its `rollForward` (by default `Minor`) keeps it on this major | Vendor update, or a `rollForward` override you have tested |
| `Unresolved` | No installed runtime satisfies it today | Already broken, or the wrong framework or architecture is installed |
| `SelfContained` | Ships its own runtime | Not affected by removing shared runtimes (but it does carry its own unpatched copy) |

The reports judge removal by **`ResolvedMajor`**, the runtime an app actually binds to today, not the version it asks for. That catches cases like an app asking for 6.0 with `Major` roll-forward that is actually running on 8.

Most apps never set `rollForward`, which means `Minor`, so they will report `Pinned` to the major they were built for. That is accurate: the .NET host won't move them to a new major. In practice a vendor update is usually what's needed. Adding `"rollForward": "Major"` to a vendor's `runtimeconfig.json` or setting `DOTNET_ROLL_FORWARD` does work, but it is unsupported by the vendor and needs testing.

### How resolution is emulated

These are the [.NET host roll-forward rules](https://learn.microsoft.com/dotnet/core/versions/selection#framework-dependent-apps-roll-forward):

- **Where `rollForward` comes from:** the framework reference's own setting, then the app-wide `runtimeOptions.rollForward`, then legacy `rollForwardOnNoCandidateFx`/`applyPatches`. A machine-wide `DOTNET_ROLL_FORWARD` is used only where the app sets nothing, and is reported in `CM_DotNetScanStatus.EnvRollForward`. The default is `Minor`.
- **Which runtimes count:** only those of the same framework name and CPU architecture. The architecture comes from the apphost `.exe` PE header, or the OS architecture for `.dll`-only apps. A runtime version folder without its `<framework>.deps.json` is ignored, as the host does. Prerelease runtimes are only considered for apps that ask for a prerelease.
- **Policies:**
  - `LatestPatch`: same major.minor.
  - `Minor`: the lowest minor ≥ requested within the same major.
  - `LatestMinor`: the highest minor within the same major.
  - `Major`: like `Minor`, else the lowest higher major.
  - `LatestMajor`: the highest version installed.
  - `Disable`: an exact match only.

  Every policy except `Disable` then takes the latest patch.

## EDR / security notes

- **No obfuscation of any kind.** There is no base64, `-EncodedCommand`, `Invoke-Expression`, `Add-Type`, hidden windows or network access. The scanner travels inside `ci/Remediation.ps1` as readable text in a single-quoted here-string, which PowerShell does not execute.
- **Fixed paths, for allow rules if your EDR wants them:**
  - Script: `%ProgramData%\DotNetDependencyScan\Invoke-DotNetDependencyScan.ps1`
  - SHA256 for v2.0.0 as built: `4B2C8291FBF7AB9D2CB8F6C19457A4A379225FAE86BBB988D16697C2ECF7E3DF`. `Build-CIScripts.ps1` prints the current value.
  - Task: `\DotNetDependencyScan`. It runs `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "…" -TimeBudgetMinutes 60` as SYSTEM.
- **No `-ExecutionPolicy Bypass` by default.** A file written locally has no Mark-of-the-Web, so `RemoteSigned` runs it unsigned.
  - If you enforce `AllSigned`: sign `src\Invoke-DotNetDependencyScan.ps1` (keep CRLF line endings), then run `Build-CIScripts.ps1 -TaskExecutionPolicy AllSigned`, then sign `ci\Discovery.ps1` and `ci\Remediation.ps1` before pasting them. The build adds no extra encoding, so the embedded signature block is written out exactly as it was signed. Check it with `Get-AuthenticodeSignature` on a test device.
  - `-TaskExecutionPolicy Inherit` omits the switch entirely so GPO decides.
- **Locked-down install folder.** It is owned by Administrators, writable only by SYSTEM and Administrators, and inheritance is removed. The scanner is deleted and rewritten whenever its hash doesn't match.
- **What the scanner touches.** It writes only to WMI (`root\cimv2`, its three classes) and its log. Everything else is read-only. It runs at BelowNormal priority.

## Limitations

- **Only apps that have a `runtimeconfig.json`.** That means framework-dependent .NET Core 3.x and .NET 5+ apps. .NET Framework 4.x apps, and apps hosting the runtime with a custom host, aren't detected.
- **Per-user settings aren't seen.** Per-user `DOTNET_ROLL_FORWARD` settings, and apps launched with `--roll-forward`, are invisible to a SYSTEM scan.
- **Partial data after a time-budget overrun.** If a scan exceeds `-TimeBudgetMinutes` (for example on file servers), the device reports `TimeBudgetExceeded`. The rows it found are updated and older rows are kept. Raise the budget with `Build-CIScripts.ps1 -TimeBudgetMinutes`, or exclude data volumes with the scanner's `-ExcludePath` default.
- **Copies inside SDKs, caches and user profiles are inventoried too.** Examples are tools in `dotnet\sdk` and `.nuget` caches. Filter these with `InUserProfile` and `AppFolder` in the reports (`03-BlockingApps.sql` has `@IncludeUserProfiles`).
- **Desktop apps depend on two frameworks.** `Microsoft.WindowsDesktop.App` itself depends on `Microsoft.NETCore.App` of the same version. The Desktop Runtime installer installs both, so remove and replace them together.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # once
Invoke-Pester .\tests
```

The tests cover runtimeconfig parsing (single and multiple frameworks, self-contained, `rollForward` precedence, legacy settings, malformed JSON) and the resolution rules for each `rollForward` policy. They only use the pure functions, so they run under PowerShell 7 on any OS as well as Windows PowerShell 5.1.

## Uninstall

1. Delete the baseline deployment.
2. Run `ci/Uninstall.ps1` as SYSTEM or an administrator, through Run Scripts, a package, or by hand.
3. Optionally remove the classes from hardware inventory in Client Settings.
