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
$LidAction = '5ca83367-6e45-459f-a27b-476b1d01c936'

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

function Enable-LidSettingAccess {
    powercfg /attributes $SubButtons $LidAction -ATTRIB_HIDE 2>$null | Out-Null
}

function Get-LidValues {
    param([string] $SchemeGuid)

    Enable-LidSettingAccess
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

    Enable-LidSettingAccess
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

function Parse-UntilTime {
    param([string] $Text)

    if ($Text -notmatch '^(?<hour>[01]\d|2[0-3])(?<minute>[0-5]\d)$') {
        throw "Invalid --until time '$Text'. Use 24-hour HHmm format like 1415."
    }

    $now = [DateTimeOffset]::Now
    $target = New-Object DateTimeOffset(
        $now.Year,
        $now.Month,
        $now.Day,
        [int]$Matches['hour'],
        [int]$Matches['minute'],
        0,
        $now.Offset
    )

    if ($target -le $now) {
        $target = $target.AddDays(1)
    }

    if (($target - $now) -gt [TimeSpan]::FromDays(1)) {
        throw 'The maximum energize duration is 1 day.'
    }

    return $target
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
    Write-Host 'PC deenergized'
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct REASON_CONTEXT {
        public uint Version;
        public uint Flags;
        public IntPtr SimpleReasonString;
    }

    public enum POWER_REQUEST_TYPE {
        PowerRequestDisplayRequired = 0,
        PowerRequestSystemRequired = 1,
        PowerRequestAwayModeRequired = 2,
        PowerRequestExecutionRequired = 3
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr PowerCreateRequest(ref REASON_CONTEXT Context);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PowerSetRequest(IntPtr PowerRequest, POWER_REQUEST_TYPE RequestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PowerClearRequest(IntPtr PowerRequest, POWER_REQUEST_TYPE RequestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@

$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1
$ES_DISPLAY_REQUIRED = [uint32]2
$ES_AWAYMODE_REQUIRED = [uint32]64
$SubButtons = '4f971e89-eebd-4455-a8de-9e59040e7347'
$LidAction = '5ca83367-6e45-459f-a27b-476b1d01c936'
$POWER_REQUEST_CONTEXT_VERSION = [uint32]0
$POWER_REQUEST_CONTEXT_SIMPLE_STRING = [uint32]1
$powerRequestHandle = [IntPtr]::Zero
$reasonString = [IntPtr]::Zero

function Start-PowerRequests {
    $script:reasonString = [Runtime.InteropServices.Marshal]::StringToHGlobalUni('energize keep-awake request')
    $context = New-Object EnergizeNative+REASON_CONTEXT
    $context.Version = $POWER_REQUEST_CONTEXT_VERSION
    $context.Flags = $POWER_REQUEST_CONTEXT_SIMPLE_STRING
    $context.SimpleReasonString = $script:reasonString

    $script:powerRequestHandle = [EnergizeNative]::PowerCreateRequest([ref]$context)
    if ($script:powerRequestHandle -eq [IntPtr]::Zero -or $script:powerRequestHandle -eq [IntPtr]::MinusOne) {
        throw "PowerCreateRequest failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }

    $requestTypes = @(
        [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestSystemRequired,
        [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestDisplayRequired,
        [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestAwayModeRequired,
        [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestExecutionRequired
    )

    foreach ($requestType in $requestTypes) {
        [EnergizeNative]::PowerSetRequest($script:powerRequestHandle, $requestType) | Out-Null
    }
}

function Restore {
    if ($script:powerRequestHandle -ne [IntPtr]::Zero -and $script:powerRequestHandle -ne [IntPtr]::MinusOne) {
        $requestTypes = @(
            [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestSystemRequired,
            [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestDisplayRequired,
            [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestAwayModeRequired,
            [EnergizeNative+POWER_REQUEST_TYPE]::PowerRequestExecutionRequired
        )
        foreach ($requestType in $requestTypes) {
            [EnergizeNative]::PowerClearRequest($script:powerRequestHandle, $requestType) | Out-Null
        }
        [EnergizeNative]::CloseHandle($script:powerRequestHandle) | Out-Null
        $script:powerRequestHandle = [IntPtr]::Zero
    }
    if ($script:reasonString -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($script:reasonString)
        $script:reasonString = [IntPtr]::Zero
    }
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

    Start-PowerRequests
    while ($true) {
        [EnergizeNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED -bor $ES_AWAYMODE_REQUIRED) | Out-Null
        if ($until -and [DateTimeOffset]::Now -ge $until) {
            Restore
            break
        }
        Start-Sleep -Seconds 10
    }
} catch {
    Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) Worker error: $($_.Exception.Message)"
    Restore
}
'@ | Set-Content -LiteralPath $WorkerPath -Encoding ASCII
}

function Start-Energize {
    param(
        $Duration,
        $UntilDate
    )

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
    $statusDisplay = 'PC energized indefinitely'
    if ($null -ne $UntilDate) {
        $untilDate = $UntilDate
        $until = $untilDate.ToString('o')
        $statusDisplay = "PC energized until $(Format-UntilTime -DateTimeOffset $untilDate)"
    } elseif ($null -ne $Duration) {
        $untilDate = [DateTimeOffset]::Now.Add($Duration)
        $until = $untilDate.ToString('o')
        $statusDisplay = "PC energized until $(Format-UntilTime -DateTimeOffset $untilDate)"
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

    $process = Start-Process -FilePath powershell.exe -ArgumentList (Join-Arguments -Arguments $workerArgs) -WindowStyle Hidden -PassThru
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

    Start-Sleep -Milliseconds 750
    $process.Refresh()
    if ($process.HasExited) {
        $details = ''
        if (Test-Path -LiteralPath $LogPath) {
            $details = (Get-Content -LiteralPath $LogPath -Tail 5) -join ' '
        }
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        throw "energize worker exited immediately. $details"
    }

    Write-Host $statusDisplay
}

function Format-UntilTime {
    param([DateTimeOffset] $DateTimeOffset)

    return $DateTimeOffset.LocalDateTime.ToString('h:mm:ss tt')
}

function Join-Arguments {
    param([string[]] $Arguments)

    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
}

$commandName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
if ($Deenergize -or $commandName -ieq 'deenergize') {
    Restore-FromState
    exit 0
}

$duration = $null
$untilDate = $null

if ($ArgsList.Count -eq 1) {
    $duration = Parse-Duration $ArgsList[0]
} elseif ($ArgsList.Count -eq 2 -and ($ArgsList[0] -eq 'until' -or $ArgsList[0] -eq '--until')) {
    $untilDate = Parse-UntilTime $ArgsList[1]
} elseif ($ArgsList.Count -gt 0) {
    throw 'Usage: energize [duration] or energize until HHmm. Examples: energize 1h, energize until 1415'
}

Start-Energize -Duration $duration -UntilDate $untilDate
