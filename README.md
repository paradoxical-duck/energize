# energize

energize is a Windows command capable of keeping your laptop awake even when the lid is closed. It is inspired by macOS's `caffeinate`.

## Usage

```powershell
energize
energize 1m # Keeps PC on for 1 minute
energize 1h # Keeps PC on for 1 hour
energize 1d # Keeps PC on for 1 day
energize until 1415 # Keeps PC on until 2:15 PM
energise 1h # British spelling also works
deenergize # Lid close goes back to Sleep
deenergise # British spelling also works
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

You can also use `until HHmm` with 24-hour time, like `energize until 1415`.

The maximum timed duration is one day.

## Install

Run this in PowerShell:

```powershell
iwr https://raw.githubusercontent.com/paradoxical-duck/energize/main/install.ps1 -UseB | iex
```

The installer clones or updates the repo under `%LOCALAPPDATA%\Programs\energize`,
adds the command shims to the user PATH, and updates PATH for the current terminal.

## Notes

`energize` blocks Windows idle sleep/display sleep using Windows power requests and `SetThreadExecutionState`.
It temporarily sets lid-close behavior to do nothing. `deenergize` sets lid-close behavior back to Sleep.
Windows lock policy is separate from sleep; if your PC is set to lock after inactivity, `energize` does not silently disable that security setting.
