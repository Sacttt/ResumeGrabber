<#
.SYNOPSIS
    Removes ResumeGrabber (app, shortcuts, PATH entry, right-click menu, caches).
    Your PDFs in Documents\ResumeGrabber are never touched.
#>
[CmdletBinding()]
param([switch]$Yes)

$ErrorActionPreference = 'Continue'
$Home_  = if ($env:RESUMEGRABBER_HOME) { $env:RESUMEGRABBER_HOME } else { Join-Path $env:LOCALAPPDATA 'ResumeGrabber' }
$BinDir = Join-Path $Home_ 'bin'

if (-not $Yes) {
    $a = Read-Host 'Remove ResumeGrabber from this PC? Your PDFs stay where they are. [y/N]'
    if ($a -notmatch '^[yY]') { Write-Host 'Cancelled.'; exit 0 }
}

foreach ($lnk in (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ResumeGrabber.lnk'),
                 (Join-Path ([Environment]::GetFolderPath('Programs')) 'ResumeGrabber.lnk')) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path 'HKCU:\Software\Classes\SystemFileAssociations\.json\shell\ResumeGrabber' -Recurse -Force -ErrorAction SilentlyContinue

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    $kept = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $BinDir }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $kept, 'User')
}

# The app folder may contain this very script, so delete it from a detached process.
$cmd = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$Home_' -Recurse -Force -ErrorAction SilentlyContinue"
Start-Process -WindowStyle Hidden -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile', '-Command', $cmd
Write-Host 'ResumeGrabber was removed. Thanks for using it!' -ForegroundColor Green
