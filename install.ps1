$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\energize'
$binDir = Join-Path $installDir 'bin'
$repoUrl = 'https://github.com/paradoxical-duck/energize.git'

if (Test-Path -LiteralPath (Join-Path $installDir '.git')) {
    git -C $installDir pull --ff-only
} elseif (Test-Path -LiteralPath $installDir) {
    $backupDir = "$installDir.backup-$(Get-Date -Format yyyyMMddHHmmss)"
    Move-Item -LiteralPath $installDir -Destination $backupDir
    git clone $repoUrl $installDir
} else {
    git clone $repoUrl $installDir
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
foreach ($commandShim in @('energize.cmd', 'energise.cmd', 'deenergize.cmd', 'deenergise.cmd')) {
    Copy-Item -LiteralPath (Join-Path $installDir $commandShim) -Destination $binDir -Force
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $binDir) {
    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $binDir } else { "$userPath;$binDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
}

if (($env:Path -split ';') -notcontains $binDir) {
    $env:Path = "$env:Path;$binDir"
}

Write-Host 'energize installed'
Write-Host 'Try: energize 5s'
