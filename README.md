# energize

energize is a Windows command capable of keeping your laptop awake even when the lid is closed. It is inspired by macOS's `caffeinate`.

## Usage

```powershell
energize
energize 1m # Keeps PC on for 1 minute
energize 1h # Keeps PC on for 1 hour
energize 1d # Keeps PC on for 1 day
deenergize # PC stays off if lid closed
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
