<#
    DotNetDependencyScan - uninstall

    Removes everything the configuration item put on the device: the scheduled task, the
    installed scanner, the three WMI classes and the registry key. Leaves the log.
    Run as SYSTEM or an administrator (ConfigMgr Run Scripts, a package, or by hand).
    Remove the baseline deployment first, or remediation will put it all back.

    Set $RemoveLegacy to $true to also remove the original TCSMUG solution's
    CM_dotnetDependencies WMI class.
#>
$RemoveLegacy = $false

$TaskName    = 'DotNetDependencyScan'
$InstallDir  = Join-Path $env:ProgramData 'DotNetDependencyScan'
$RegistryKey = 'HKLM:\SOFTWARE\DotNetDependencyScan'
$Classes     = @('CM_DotNetAppDependency', 'CM_DotNetRuntime', 'CM_DotNetScanStatus')
if ($RemoveLegacy) { $Classes += 'CM_dotnetDependencies' }

$removed = New-Object System.Collections.Generic.List[string]

$task = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskPath '\' -TaskName $TaskName }
    Unregister-ScheduledTask -TaskPath '\' -TaskName $TaskName -Confirm:$false
    $removed.Add('Task')
}
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    $removed.Add('Files')
}
foreach ($class in $Classes) {
    if (Get-CimClass -Namespace 'root\cimv2' -ClassName $class -ErrorAction SilentlyContinue) {
        ([wmiclass]('\\.\root\cimv2:{0}' -f $class)).Delete()
        $removed.Add($class)
    }
}
if (Test-Path -LiteralPath $RegistryKey) {
    Remove-Item -LiteralPath $RegistryKey -Recurse -Force
    $removed.Add('Registry')
}

if ($removed.Count -eq 0) { 'Nothing to remove' } else { 'Removed: ' + ($removed -join ';') }
