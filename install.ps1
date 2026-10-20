<#
.SYNOPSIS
    Installs ResumeGrabber for the current user (no admin, no Docker, no Python).

.DESCRIPTION
    One-liner:
        irm https://raw.githubusercontent.com/Sacttt/ResumeGrabber/main/install.ps1 | iex

    What it does:
      * copies the app to %LOCALAPPDATA%\ResumeGrabber\app
      * adds the `resumegrabber` command to your user PATH
      * creates Desktop + Start Menu shortcuts
      * adds "Convert with ResumeGrabber" to the right-click menu of .json files
      * pre-downloads a portable Node.js and resume.io's rendering engine
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$NoShortcuts,
    [switch]$NoContextMenu,
    [switch]$SkipPrefetch,
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$Repo    = 'Sacttt/ResumeGrabber'
$Home_   = if ($env:RESUMEGRABBER_HOME) { $env:RESUMEGRABBER_HOME } else { Join-Path $env:LOCALAPPDATA 'ResumeGrabber' }
$AppDir  = Join-Path $Home_ 'app'
$BinDir  = Join-Path $Home_ 'bin'

function Say([string]$t, [string]$c = 'Gray') { if (-not $Quiet) { Write-Host $t -ForegroundColor $c } }
function Step([string]$t) { Say "  > $t" 'Cyan' }

if ($env:OS -ne 'Windows_NT') { throw 'This installer is for Windows. On macOS/Linux run ResumeGrabber.ps1 with pwsh directly.' }

Say ''
Say '  ResumeGrabber installer' 'Magenta'
Say '  -----------------------' 'DarkGray'

foreach ($d in $Home_, $BinDir) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# ---------------------------------------------------------------- 1. get the app files
$localSource = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ResumeGrabber.ps1')) -and ($PSScriptRoot -ne $AppDir)) {
    $localSource = $PSScriptRoot
}

$staging = Join-Path $Home_ ('staging-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    if ($localSource) {
        Step "Installing from $localSource"
        $src = $localSource
    } else {
        Step "Downloading github.com/$Repo ($Branch)"
        $zip = Join-Path $staging 'src.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        $src = (Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1).FullName
    }

    Step 'Copying files'
    $newApp = Join-Path $staging 'app'
    New-Item -ItemType Directory -Path $newApp -Force | Out-Null
    foreach ($item in 'ResumeGrabber.ps1', 'install.ps1', 'uninstall.ps1', 'lib', 'engine', 'README.md', 'LICENSE') {
        $p = Join-Path $src $item
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $newApp -Recurse -Force }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $newApp 'ResumeGrabber.ps1'))) { throw 'Download looks incomplete (ResumeGrabber.ps1 missing).' }
    if (Test-Path -LiteralPath $AppDir) { Remove-Item -LiteralPath $AppDir -Recurse -Force }
    Move-Item -LiteralPath $newApp -Destination $AppDir
    Get-ChildItem -LiteralPath $AppDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$Ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Main = Join-Path $AppDir 'ResumeGrabber.ps1'

# ---------------------------------------------------------------- 2. icon (drawn on the fly, no binary in the repo)
$Icon = Join-Path $Home_ 'resumegrabber.ico'
try {
    Add-Type -AssemblyName System.Drawing
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $rect = New-Object System.Drawing.Rectangle 8, 8, 240, 240
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 0, 200, 255)), ([System.Drawing.Color]::FromArgb(255, 190, 40, 220)), 45
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 56
    $path.AddArc(8, 8, $r, $r, 180, 90); $path.AddArc(248 - $r, 8, $r, $r, 270, 90)
    $path.AddArc(248 - $r, 248 - $r, $r, $r, 0, 90); $path.AddArc(8, 248 - $r, $r, $r, 90, 90); $path.CloseFigure()
    $g.FillPath($brush, $path)
    # a little "page" with a folded corner
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(245, 255, 255, 255))
    $page = New-Object System.Drawing.Drawing2D.GraphicsPath
    $page.AddPolygon([System.Drawing.Point[]]@((New-Object System.Drawing.Point 70, 44), (New-Object System.Drawing.Point 160, 44), (New-Object System.Drawing.Point 194, 78), (New-Object System.Drawing.Point 194, 212), (New-Object System.Drawing.Point 70, 212)))
    $g.FillPath($white, $page)
    $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 120, 40, 200))
    $font = New-Object System.Drawing.Font 'Segoe UI', 54, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString('RG', $font, $ink, (New-Object System.Drawing.RectangleF 70, 70, 124, 110), $fmt)
    $bar = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0, 180, 240))
    $g.FillRectangle($bar, 92, 180, 80, 10)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $png = $ms.ToArray()
    $fs = [IO.File]::Create($Icon); $bw = New-Object IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)          # ICONDIR
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)  # 256x256
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png); $bw.Close()
} catch { $Icon = "$Ps,0" }

# ---------------------------------------------------------------- 3. command on PATH
Step 'Adding the "resumegrabber" command'
$shim = "@echo off`r`n`"$Ps`" -NoProfile -ExecutionPolicy Bypass -File `"$Main`" %*`r`n"
[IO.File]::WriteAllText((Join-Path $BinDir 'resumegrabber.cmd'), $shim, (New-Object Text.ASCIIEncoding))
$explorerShim = "@echo off`r`nset RG_FROM_EXPLORER=1`r`n`"$Ps`" -NoProfile -ExecutionPolicy Bypass -File `"$Main`" -Open %*`r`n"
[IO.File]::WriteAllText((Join-Path $BinDir 'rg-explorer.cmd'), $explorerShim, (New-Object Text.ASCIIEncoding))

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $BinDir) {
    $newPath = (@($userPath.TrimEnd(';'), $BinDir) | Where-Object { $_ }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
}
if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$env:Path;$BinDir" }

# ---------------------------------------------------------------- 4. shortcuts
if (-not $NoShortcuts) {
    Step 'Creating Desktop and Start Menu shortcuts'
    $wsh = New-Object -ComObject WScript.Shell
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ResumeGrabber.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'ResumeGrabber.lnk')
    )
    foreach ($lnkPath in $targets) {
        try {
            $lnk = $wsh.CreateShortcut($lnkPath)
            $lnk.TargetPath = $Ps
            $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Main`""
            $lnk.WorkingDirectory = $AppDir
            $lnk.IconLocation = $Icon
            $lnk.Description = 'Turn your resume.io resume into a PDF'
            $lnk.Save()
        } catch { Say "    (couldn't create $lnkPath)" 'DarkYellow' }
    }
}

# ---------------------------------------------------------------- 5. Explorer right-click
if (-not $NoContextMenu) {
    Step 'Adding "Convert with ResumeGrabber" to the .json right-click menu'
    $key = 'HKCU:\Software\Classes\SystemFileAssociations\.json\shell\ResumeGrabber'
    New-Item -Path "$key\command" -Force | Out-Null
    Set-ItemProperty -Path $key -Name '(default)' -Value 'Convert with ResumeGrabber'
    Set-ItemProperty -Path $key -Name 'Icon' -Value $Icon
    Set-ItemProperty -Path "$key\command" -Name '(default)' -Value ('"{0}" "%1"' -f (Join-Path $BinDir 'rg-explorer.cmd'))
}

# ---------------------------------------------------------------- 6. prefetch Node + engine
if (-not $SkipPrefetch) {
    try {
        . (Join-Path (Join-Path $AppDir 'lib') 'Core.ps1')
        Initialize-RGDirs
        $node = Get-RGNode -OnStatus { param($m) Step $m }
        Say ("    Node.js {0} ready" -f (& $node --version)) 'DarkGray'
        $b = Get-RGBundle -OnStatus { param($m) Step $m }
        Say "    resume.io engine ready ($($b.Entry))" 'DarkGray'
    } catch {
        Say "    Prefetch skipped: $($_.Exception.Message)" 'DarkYellow'
        Say '    (no problem - it will be downloaded on first use)' 'DarkGray'
    }
}

Say ''
Say '  Installed!' 'Green'
Say '    * Desktop / Start Menu:  ResumeGrabber' 'White'
Say '    * Any terminal:          resumegrabber   (open a NEW terminal first)' 'White'
Say '    * Explorer:              right-click a .json -> Convert with ResumeGrabber' 'White'
Say ''
