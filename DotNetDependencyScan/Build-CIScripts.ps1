<#
.SYNOPSIS
    Generates ci\Discovery.ps1 and ci\Remediation.ps1 from the templates and the scanner.

.DESCRIPTION
    Embeds src\Invoke-DotNetDependencyScan.ps1 into the remediation script as plain text,
    computes the SHA256 of the file remediation will write, and stamps the same hash and
    task settings into the discovery script so the two can never drift apart.

    Rerun this after changing the scanner or any parameter below, then paste the two
    generated scripts into the configuration item (replacing the previous text).

.PARAMETER TaskExecutionPolicy
    Execution policy passed to powershell.exe by the scheduled task. RemoteSigned (default)
    runs the locally written, unsigned scanner without needing -ExecutionPolicy Bypass.
    Use AllSigned if you sign the scanner, or Inherit to omit the switch and follow GPO.

.EXAMPLE
    .\Build-CIScripts.ps1

.EXAMPLE
    .\Build-CIScripts.ps1 -ScheduleDay Sunday -ScheduleTime 03:00 -TaskExecutionPolicy AllSigned
#>
[CmdletBinding()]
param(
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$ScheduleDay = 'Wednesday',
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$ScheduleTime = '12:00',
    [ValidateRange(0, 23)]
    [int]$RandomDelayHours = 4,
    [ValidateSet('RemoteSigned', 'AllSigned', 'Inherit', 'Bypass')]
    [string]$TaskExecutionPolicy = 'RemoteSigned',
    [ValidateRange(1, 1440)]
    [int]$TimeBudgetMinutes = 60,
    [ValidateRange(1, 90)]
    [int]$MaxAgeDays = 10
)
$ErrorActionPreference = 'Stop'

function ConvertTo-CrLf([string]$Text) {
    (($Text -replace "`r`n", "`n") -replace "`n", "`r`n").TrimEnd() + "`r`n"
}

$utf8Bom = New-Object System.Text.UTF8Encoding $true
$scannerText = ConvertTo-CrLf ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'src\Invoke-DotNetDependencyScan.ps1')))

if ($scannerText -match "(?m)^'@") {
    throw "The scanner contains a line starting with '@, which would end the here-string in the remediation script."
}
if ($scannerText -match '[^\x00-\x7F]') {
    throw 'The scanner contains non-ASCII characters; keep it ASCII so it survives being pasted into ConfigMgr unchanged.'
}
if ($scannerText -notmatch "(?m)^\`$ScannerVersion = '([^']+)'") {
    throw 'Could not find the $ScannerVersion line in the scanner.'
}
$scannerVersion = $Matches[1]

# Hash exactly what Install-Scanner writes: UTF-8 with BOM, CRLF line endings.
[byte[]]$bytes = $utf8Bom.GetPreamble() + $utf8Bom.GetBytes($scannerText)
$sha256 = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')

# Any change to these settings changes the signature, which makes discovery report
# TaskOutdated so remediation re-registers the task.
$taskSignature = 'v{0};{1};{2};{3}h;{4};{5}m' -f $scannerVersion, $ScheduleDay, $ScheduleTime, $RandomDelayHours, $TaskExecutionPolicy, $TimeBudgetMinutes

$tokens = [ordered]@{
    '__SCANNER_VERSION__'       = $scannerVersion
    '__SCANNER_SHA256__'        = $sha256
    '__TASK_SIGNATURE__'        = $taskSignature
    '__TASK_EXECUTION_POLICY__' = $TaskExecutionPolicy
    '__SCHEDULE_DAY__'          = $ScheduleDay
    '__SCHEDULE_TIME__'         = $ScheduleTime
    '__RANDOM_DELAY_HOURS__'    = [string]$RandomDelayHours
    '__TIME_BUDGET_MINUTES__'   = [string]$TimeBudgetMinutes
    '__MAX_AGE_DAYS__'          = [string]$MaxAgeDays
    '__SCANNER_TEXT__'          = $scannerText.TrimEnd()
}

$outDir = Join-Path $PSScriptRoot 'ci'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

foreach ($name in 'Discovery', 'Remediation') {
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "templates\$name.template.ps1"))
    # __SCANNER_TEXT__ goes last so nothing inside the scanner is mistaken for a token.
    foreach ($token in $tokens.Keys) { $text = $text.Replace($token, $tokens[$token]) }
    $outPath = Join-Path $outDir "$name.ps1"
    [IO.File]::WriteAllText($outPath, (ConvertTo-CrLf $text), $utf8Bom)
    Write-Host "Wrote $outPath"
}

Write-Host "Scanner version : $scannerVersion"
Write-Host "Scanner SHA256  : $sha256  (%ProgramData%\DotNetDependencyScan\Invoke-DotNetDependencyScan.ps1)"
Write-Host "Task signature  : $taskSignature"
