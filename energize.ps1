param(
    [switch] $Deenergize,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ArgsList
)

$ErrorActionPreference = 'Stop'

$BaseDir = Join-Path $env:LOCALAPPDATA 'energize'
$StatePath = Join-Path $BaseDir 'state.json'
$LogPath = Join-Path $BaseDir 'energize.log'
$WorkerPath = Join-Path $BaseDir 'energize-worker.ps1'

$SubButtons = '4f971e89-eebd-4455-a8de-9e59040e7347'
$LidAction = '5ca83367-6e45-459f-a27b-476b1d01c9360'

function Ensure-BaseDir {
    if (-not (Test-Path -LiteralPath $BaseDir)) {
        New-Item -ItemType Directory -Path $BaseDir | Out-Null
    }
}

function Get-ActiveSchemeGuid {
    $line = powercfg /getactivescheme
    if ($line -match 'Power Scheme GUID:\s*([a-fA-F0-9-]+)') {
        return $Matches[1]
    }
    throw 'Could not find the active Windows power scheme.'
}

function Get-LidValues {
    param([string] $SchemeGuid)

    $query = powercfg /query $SchemeGuid $SubButtons
    $ac = $null
    $dc = $null
    $inLidSetting = $false
    foreach ($line in $query) {
        if ($line -match 'Power Setting GUID:\s*([a-fA-F0-9-]+)') {
            $inLidSetting = ($Matches[1] -ieq $LidAction)
            continue
        }
        if (-not $inLidSetting) {
            continue
        }
        if ($line -match 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') {
            $ac = [Convert]::ToInt32($Matches[1], 16)
        }
        if ($line -match 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)') {
            $dc = [Convert]::ToInt32($Matches[1], 16)
        }
    }

    if ($null -eq $ac -or $null -eq $dc) {
        return $null
    }

    [pscustomobject]@{
        AC = $ac
        DC = $dc
    }
}

function Set-LidValues {
    param(
        [string] $SchemeGuid,
        [int] $AC,
        [int] $DC
    )

    $acResult = powercfg /setacvalueindex $SchemeGuid $SubButtons $LidAction $AC 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set AC lid-close behavior: $acResult"
    }
    $dcResult = powercfg /setdcvalueindex $SchemeGuid $SubButtons $LidAction $DC 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set DC lid-close behavior: $dcResult"
    }
    powercfg /setactive $SchemeGuid | Out-Null
}

function Parse-Duration {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    if ($Text -notmatch '^(?<num>\d+)(?<unit>[smhd])$') {
        throw "Invalid duration '$Text'. Use formats like 30s, 10m, 1h, or 1d."
    }

    $num = [int]$Matches['num']
    $unit = $Matches['unit']
    if ($num -le 0) {
        throw 'Duration must be greater than zero.'
    }

    $span = switch ($unit) {
        's' { [TimeSpan]::FromSeconds($num) }
        'm' { [TimeSpan]::FromMinutes($num) }
        'h' { [TimeSpan]::FromHours($num) }
        'd' { [TimeSpan]::FromDays($num) }
    }

    if ($span -gt [TimeSpan]::FromDays(1)) {
        throw 'The maximum energize duration is 1 day.'
    }

    return $span
}

function Stop-ExistingWorker {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return
    }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        if ($state.Pid) {
            $process = Get-Process -Id ([int]$state.Pid) -ErrorAction SilentlyContinue
            if ($process) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) Existing worker cleanup warning: $($_.Exception.Message)"
    }
}

function Restore-FromState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        Write-Host 'energize is not currently active.'
        return
    }

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Stop-ExistingWorker

    if ($state.LidManaged -and $state.SchemeGuid -and $null -ne $state.OriginalLidAC -and $null -ne $state.OriginalLidDC) {
        Set-LidValues -SchemeGuid $state.SchemeGuid -AC ([int]$state.OriginalLidAC) -DC ([int]$state.OriginalLidDC)
    }

    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    Write-Host 'deenergized'
}

function Install-Worker {
    Ensure-BaseDir
    @'
param(
    [string] $UntilIso,
    [string] $StatePath,
    [string] $LogPath,
    [string] $SchemeGuid,
    [string] $LidManaged,
    [int] $OriginalLidAC,
    [int] $OriginalLidDC
)

$ErrorActionPreference = 'SilentlyContinue'

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class EnergizeNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

$ES_CONTINUOUS = 0x80000000
$ES_SYSTEM_REQUIRED = 0x00000001
$ES_DISPLAY_REQUIRED = 0x00000002
$SubButtons = '4f971e89-eebd-4455-a8de-9e59040e7347'
$LidAction = '5ca83367-6e45-459f-a27b-476b1d01c9360'

function Restore {
    [EnergizeNative]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    if ($LidManaged -eq 'true' -and $SchemeGuid) {
        powercfg /setacvalueindex $SchemeGuid $SubButtons $LidAction $OriginalLidAC | Out-Null
        powercfg /setdcvalueindex $SchemeGuid $SubButtons $LidAction $OriginalLidDC | Out-Null
        powercfg /setactive $SchemeGuid | Out-Null
    }
    Remove-Item -LiteralPath $StatePath -Force
}

try {
    $until = $null
    if ($UntilIso) {
        $until = [DateTimeOffset]::Parse($UntilIso)
    }

    while ($true) {
        [EnergizeNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED) | Out-Null
        if ($until -and [DateTimeOffset]::Now -ge $until) {
            Restore
            break
        }
        Start-Sleep -Seconds 30
    }
} catch {
    Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) Worker error: $($_.Exception.Message)"
    Restore
}
'@ | Set-Content -LiteralPath $WorkerPath -Encoding ASCII
}

function Start-Energize {
    param($Duration)

    Ensure-BaseDir
    Install-Worker
    Stop-ExistingWorker

    $scheme = Get-ActiveSchemeGuid
    $lid = Get-LidValues -SchemeGuid $scheme
    $lidManaged = $false
    if ($null -ne $lid) {
        try {
            Set-LidValues -SchemeGuid $scheme -AC 0 -DC 0
            $lidManaged = $true
        } catch {
            Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) Lid setting warning: $($_.Exception.Message)"
        }
    }

    $until = $null
    $untilDisplay = 'indefinitely'
    if ($null -ne $Duration) {
        $untilDate = [DateTimeOffset]::Now.Add($Duration)
        $until = $untilDate.ToString('o')
        $untilDisplay = Format-Duration -Duration $Duration
    }

    $workerArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $WorkerPath,
        '-StatePath', $StatePath,
        '-LogPath', $LogPath,
        '-SchemeGuid', $scheme,
        '-LidManaged', $lidManaged.ToString().ToLowerInvariant(),
        '-OriginalLidAC', $(if ($lid) { $lid.AC } else { 0 }),
        '-OriginalLidDC', $(if ($lid) { $lid.DC } else { 0 })
    )
    if ($until) {
        $workerArgs += @('-UntilIso', $until)
    }

    $process = Start-Process -FilePath powershell.exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru
    $state = [pscustomobject]@{
        Pid = $process.Id
        StartedAt = [DateTimeOffset]::Now.ToString('o')
        Until = $until
        SchemeGuid = $scheme
        LidManaged = $lidManaged
        OriginalLidAC = $(if ($lid) { $lid.AC } else { $null })
        OriginalLidDC = $(if ($lid) { $lid.DC } else { $null })
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding ASCII

    Write-Host "energized $untilDisplay"
}

function Format-Duration {
    param($Duration)

    if ($Duration.TotalDays -ge 1 -and $Duration.TotalDays % 1 -eq 0) {
        $value = [int]$Duration.TotalDays
        $unit = 'day'
    } elseif ($Duration.TotalHours -ge 1 -and $Duration.TotalHours % 1 -eq 0) {
        $value = [int]$Duration.TotalHours
        $unit = 'hour'
    } elseif ($Duration.TotalMinutes -ge 1 -and $Duration.TotalMinutes % 1 -eq 0) {
        $value = [int]$Duration.TotalMinutes
        $unit = 'minute'
    } else {
        $value = [int]$Duration.TotalSeconds
        $unit = 'second'
    }

    if ($value -ne 1) {
        $unit = "${unit}s"
    }

    return "for $value $unit"
}

$commandName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
if ($Deenergize -or $commandName -ieq 'deenergize') {
    Restore-FromState
    exit 0
}

if ($ArgsList.Count -gt 1) {
    throw 'Usage: energize [duration]. Example: energize 1h'
}

$duration = $null
if ($ArgsList.Count -eq 1) {
    $duration = Parse-Duration $ArgsList[0]
}

Start-Energize -Duration $duration
