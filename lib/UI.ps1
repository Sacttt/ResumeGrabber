# ResumeGrabber - terminal UI helpers (banner, arrow-key menus, spinner, prompts)

$script:RG_Interactive = $true
try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $script:RG_Interactive = $false } } catch { $script:RG_Interactive = $false }

$script:SpinFrames = @('|', '/', '-', '\')
$script:SpinIndex = 0
$script:SpinLabel = ''

function Set-RGConsole {
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $Host.UI.RawUI.WindowTitle = "ResumeGrabber $($script:RG_VERSION)"
    } catch { }
}

function Write-C([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) {
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
}

function Show-RGBanner {
    try { if ($script:RG_Interactive) { Clear-Host } } catch { }
    $art = @(
        '  ____                                ____           _     _               ',
        ' |  _ \ ___  ___ _   _ _ __ ___   ___/ ___|_ __ __ _| |__ | |__   ___ _ __ ',
        ' | |_) / _ \/ __| | | | ''_ ` _ \ / _ \ |  _| ''__/ _` | ''_ \| ''_ \ / _ \ ''__|',
        ' |  _ <  __/\__ \ |_| | | | | | |  __/ |_| | | | (_| | |_) | |_) |  __/ |   ',
        ' |_| \_\___||___/\__,_|_| |_| |_|\___|\____|_|  \__,_|_.__/|_.__/ \___|_|   '
    )
    $colors = @('Cyan', 'Cyan', 'DarkCyan', 'Magenta', 'DarkMagenta')
    Write-Host ''
    for ($i = 0; $i -lt $art.Count; $i++) { Write-C $art[$i] $colors[$i] }
    Write-Host ''
    Write-C '   resume.io  ->  pixel-perfect, multi-page, vector PDF' 'White' -NoNewline
    Write-C ("    v{0}" -f $script:RG_VERSION) 'DarkGray'
    Write-C '   100% local - no Docker, no Python, no account sharing' 'DarkGray'
    Write-Host ''
}

function Write-RGRule { Write-C ('   ' + ('-' * 66)) 'DarkGray' }

function Write-Step([string]$Text) {
    Stop-Spinner
    Write-C '   > ' 'Cyan' -NoNewline; Write-C $Text 'Gray'
    $script:SpinLabel = $Text
}

function Write-Ok([string]$Text)   { Stop-Spinner; Write-C '   [OK] ' 'Green' -NoNewline; Write-C $Text 'White' }
function Write-Warn([string]$Text) { Stop-Spinner; Write-C '   [!]  ' 'Yellow' -NoNewline; Write-C $Text 'Yellow' }
function Write-Err([string]$Text)  { Stop-Spinner; Write-C '   [X]  ' 'Red' -NoNewline; Write-C $Text 'Red' }
function Write-Info([string]$Text) { Write-C "   $Text" 'DarkGray' }

$script:SpinActive = $false
function Step-Spinner {
    if (-not $script:RG_Interactive) { return }
    $f = $script:SpinFrames[$script:SpinIndex % 4]; $script:SpinIndex++
    Write-Host ("`r     {0}  working..." -f $f) -ForegroundColor Magenta -NoNewline
    $script:SpinActive = $true
}
function Stop-Spinner {
    if ($script:SpinActive) { Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline; $script:SpinActive = $false }
}

function Read-RGKey {
    if (-not $script:RG_Interactive) { return $null }
    return [Console]::ReadKey($true)
}

function Wait-RGKey([string]$Prompt = 'Press any key to return to the menu') {
    Write-Host ''
    Write-C "   $Prompt" 'DarkGray'
    if ($script:RG_Interactive) { $null = [Console]::ReadKey($true) } else { $null = Read-Host }
}

function Show-RGMenu {
    <# Arrow-key menu. Items: @(@{Key='1'; Label='...'; Hint='...'}). Returns selected Key. #>
    param([string]$Title, [array]$Items, [int]$Selected = 0)
    if (-not $script:RG_Interactive) {
        Write-C "   $Title" 'White'
        foreach ($it in $Items) { Write-C ("   [{0}] {1}" -f $it.Key, $it.Label) 'Gray' }
        $k = Read-Host '   Choose'
        return $k
    }
    $top = $null
    try { [Console]::CursorVisible = $false } catch { }
    try {
        Write-C "   $Title" 'White'
        Write-Host ''
        $drawn = $false
        while ($true) {
            if ($drawn) { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $Items.Count - 2)) }
            $drawn = $true
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $it = $Items[$i]
                $line = ('[{0}] {1}' -f $it.Key, $it.Label).PadRight(40)
                if ($i -eq $Selected) {
                    Write-C '  >> ' 'Magenta' -NoNewline
                    Write-Host $line -ForegroundColor Black -BackgroundColor Cyan -NoNewline
                    Write-C ('  ' + ([string]$it.Hint).PadRight(36)) 'DarkCyan'
                } else {
                    Write-C '     ' 'Gray' -NoNewline
                    Write-C $line 'Gray' -NoNewline
                    Write-C ('  ' + (' ' * 36)) 'Gray'
                }
            }
            Write-Host ''
            Write-C '   Up/Down + Enter, or press the key in [brackets]' 'DarkGray'
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $Selected = ($Selected - 1 + $Items.Count) % $Items.Count; continue }
                'DownArrow' { $Selected = ($Selected + 1) % $Items.Count; continue }
                'Enter'     { return $Items[$Selected].Key }
                'Escape'    { return 'Q' }
            }
            $ch = [string]$key.KeyChar
            foreach ($it in $Items) { if ($it.Key -ieq $ch) { return $it.Key } }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

function Read-RGYesNo([string]$Question, [bool]$Default = $true) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    Write-C "   $Question $suffix " 'White' -NoNewline
    if ($script:RG_Interactive) {
        while ($true) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { Write-Host ''; return $Default }
            if ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y') { Write-Host 'y'; return $true }
            if ($k.KeyChar -eq 'n' -or $k.KeyChar -eq 'N') { Write-Host 'n'; return $false }
        }
    }
    $a = Read-Host
    if (-not $a) { return $Default }
    return ($a -match '^[yY]')
}

function Read-RGText([string]$Question, [string]$Default = '') {
    $hint = ''
    if ($Default) { $hint = " (Enter = $Default)" }
    Write-C "   $Question$hint" 'White'
    $a = Read-Host '   '
    if (-not $a) { return $Default }
    return $a.Trim().Trim('"').Trim("'")
}

function Select-RGFile([string]$Title = 'Pick your resume JSON', [string]$Filter = 'Resume JSON (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*', [string]$InitialDir) {
    if ($script:RG_IsWindows) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = $Title; $dlg.Filter = $Filter; $dlg.Multiselect = $true
            if ($InitialDir -and (Test-Path -LiteralPath $InitialDir)) { $dlg.InitialDirectory = $InitialDir }
            $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
            if ($dlg.ShowDialog($owner) -eq 'OK') { return @($dlg.FileNames) }
            return @()
        } catch { }
    }
    $p = Read-RGText 'Path to the JSON file (you can drag & drop it here)'
    if ($p) { return @($p) }
    return @()
}

function Select-RGFolder([string]$Description = 'Pick a folder', [string]$Initial) {
    if ($script:RG_IsWindows) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $Description
            if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dlg.SelectedPath = $Initial }
            $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
            if ($dlg.ShowDialog($owner) -eq 'OK') { return $dlg.SelectedPath }
            return $null
        } catch { }
    }
    return (Read-RGText 'Folder path' $Initial)
}

function Open-RGItem([string]$Path) {
    try {
        if ($script:RG_IsWindows) { Invoke-Item -LiteralPath $Path }
        elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $Path *> $null }
        elseif (Get-Command open -ErrorAction SilentlyContinue) { & open $Path }
    } catch { Write-Warn "Couldn't open $Path" }
}

function Show-RGInExplorer([string]$File) {
    if ($script:RG_IsWindows) { Start-Process explorer.exe -ArgumentList "/select,`"$File`"" } else { Open-RGItem (Split-Path -Parent $File) }
}

function Open-RGUrl([string]$Url) {
    try {
        if ($script:RG_IsWindows) { Start-Process $Url } else { Open-RGItem $Url }
    } catch { Write-Info "Open this in your browser: $Url" }
}
