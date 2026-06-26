# energize

Windows keep-awake commands inspired by macOS `caffeinate`.

## Usage

```powershell
energize
energize 1m
energize 1h
energize 1d
deenergize
```

`energize` with no duration keeps the machine awake indefinitely until `deenergize` is run.

Example output:

```powershell
PC energized until 10:34:18 AM
PC energized indefinitely
PC deenergized
```

Durations support:

- `s` for seconds
- `m` for minutes
- `h` for hours
- `d` for days

The maximum timed duration is one day.

## Install

Copy these files into a folder on your PATH:

- `energize.cmd`
- `deenergize.cmd`
- `energize.ps1`
- `deenergize.ps1`

For example:

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\energize"
$binDir = "$installDir\bin"
New-Item -ItemType Directory -Force $installDir, $binDir
Copy-Item .\energize.ps1, .\deenergize.ps1 $installDir -Force
Copy-Item .\energize.cmd, .\deenergize.cmd $binDir -Force
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$binDir", 'User')
```

Open a new terminal after installing.

## Notes

`energize` blocks Windows idle sleep/display sleep using `SetThreadExecutionState`.
When Windows exposes lid-close power settings through `powercfg`, it temporarily sets lid-close behavior to do nothing and restores the original values on `deenergize`.
Windows lock policy is separate from sleep; if your PC is set to lock after inactivity, `energize` does not silently disable that security setting.
