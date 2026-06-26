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

Run this in PowerShell:

```powershell
iwr https://raw.githubusercontent.com/paradoxical-duck/energize/main/install.ps1 -UseB | iex
```

The installer clones or updates the repo under `%LOCALAPPDATA%\Programs\energize`,
adds the command shims to the user PATH, and updates PATH for the current terminal.

## Notes

`energize` blocks Windows idle sleep/display sleep using `SetThreadExecutionState`.
When Windows exposes lid-close power settings through `powercfg`, it temporarily sets lid-close behavior to do nothing and restores the original values on `deenergize`.
Windows lock policy is separate from sleep; if your PC is set to lock after inactivity, `energize` does not silently disable that security setting.

## Non-admin test

```powershell
energize 5m
Get-Content "$env:LOCALAPPDATA\energize\state.json"
Get-Process -Id (Get-Content "$env:LOCALAPPDATA\energize\state.json" | ConvertFrom-Json).Pid
deenergize
```

If `Get-Process` returns a `powershell` process, the keep-awake worker is running.
