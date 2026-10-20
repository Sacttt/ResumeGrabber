<#
.SYNOPSIS
    ResumeGrabber - turn your resume.io resume into a pixel-perfect, multi-page vector PDF.

.DESCRIPTION
    Runs resume.io's own rendering engine locally with a portable Node.js runtime.
    No Docker, no Python, no admin rights. Run without arguments for the interactive app.

.EXAMPLE
    resumegrabber                         # interactive app
    resumegrabber resume.json             # convert one file
    resumegrabber *.json -Out C:\CVs      # convert many into a folder
    resumegrabber -Clipboard -Open        # convert the JSON you just copied, then open it
    resumegrabber -Watch                  # auto-convert every resume JSON you download/copy
    resumegrabber -Doctor                 # diagnose problems
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path,
    [Alias('o')][string]$Out,
    [string]$Locale,
    [switch]$Clipboard,
    [switch]$Watch,
    [switch]$Open,
    [switch]$Doctor,
    [switch]$Update,
    [switch]$RefreshEngine,
    [switch]$Version,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Core.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'UI.ps1')
Initialize-RGDirs

# ================================================================= shared actions
function Convert-RGJson {
    param([string]$JsonText, [string]$Label, [string]$OutPath, [switch]$OpenAfter, [switch]$NoOpen)
    $settings = Get-RGSettings
    try {
        $info = Get-RGResumeInfo $JsonText
        $who = @($info.Name, $info.Title) | Where-Object { $_ }
        if ($who) { Write-Step ("Resume: " + ($who -join '  |  ')) } else { Write-Step "Resume: $Label" }
        Backup-RGJson $JsonText $info
        $r = Invoke-RGRender -JsonText $JsonText -OutPath $OutPath -Locale $Locale -SourceLabel $Label `
                -OnStatus { param($m) Write-Step $m } -OnTick { Step-Spinner }
        Stop-Spinner
        if ($r.Offline) { Write-Warn 'resume.io was unreachable for discovery - used the cached engine.' }
        Write-Ok ("{0} page(s), {1} KB in {2}s" -f $r.Pages, $r.SizeKB, $r.Seconds)
        Write-C '        ' 'Gray' -NoNewline; Write-C $r.Output 'Cyan'
        if (-not $NoOpen -and ($OpenAfter -or $settings.OpenAfterRender)) { Open-RGItem $r.Output }
        return $r
    } catch {
        Write-Err ($_.Exception.Message)
        Write-RGLog "convert failed ($Label): $($_.Exception.Message)"
        return $null
    }
}

function Backup-RGJson([string]$JsonText, $Info) {
    try {
        $dir = Join-Path (Get-RGHome) 'resumes'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $id = $Info.Id; if (-not $id) { $id = $Info.Token }; if (-not $id) { $id = 'resume' }
        Write-Utf8NoBom (Join-Path $dir ((ConvertTo-SafeFileName $id) + '.json')) $JsonText
    } catch { }
}

function Convert-RGFile([string]$File, [string]$OutPath, [switch]$OpenAfter, [switch]$NoOpen) {
    $full = (Resolve-Path -LiteralPath $File).Path
    $text = [IO.File]::ReadAllText($full)
    $json = Get-JsonFromText $text
    if (-not $json) { Write-Err "$([IO.Path]::GetFileName($full)) is not valid JSON."; return $null }
    return (Convert-RGJson -JsonText $json -Label ([IO.Path]::GetFileName($full)) -OutPath $OutPath -OpenAfter:$OpenAfter -NoOpen:$NoOpen)
}

function Get-RGClipboardText {
    try { return (Get-Clipboard -Raw -ErrorAction Stop) } catch { }
    try { return ((Get-Clipboard -ErrorAction Stop) -join "`n") } catch { return '' }
}

function Wait-RGClipboardJson {
    <# Polls the clipboard until it holds JSON that passes $Accept. Esc cancels. #>
    param([scriptblock]$Accept, [string]$Waiting = 'Waiting for you to copy the page')
    $initial = Get-RGClipboardText
    $frames = @('.  ', '.. ', '...', '   '); $i = 0
    while ($true) {
        if ($script:RG_Interactive -and [Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape' -or $k.KeyChar -eq 'q') { Write-Host ''; return $null }
        }
        $now = Get-RGClipboardText
        if ($now -and $now -ne $initial) {
            $json = Get-JsonFromText $now
            if ($json) {
                $obj = ConvertFrom-RGJson $json
                if (& $Accept $obj) { Write-Host ("`r" + (' ' * 70) + "`r") -NoNewline; return $json }
            }
            $initial = $now
            Write-Host ''
            Write-Warn "That's not the right page yet - copy it again (Ctrl+A, Ctrl+C)."
        }
        if ($script:RG_Interactive) {
            Write-Host ("`r   {0}{1}   (Esc to cancel)" -f $Waiting, $frames[$i % 4]) -ForegroundColor Magenta -NoNewline
        }
        $i++
        Start-Sleep -Milliseconds 400
    }
}

function Get-RGResumeList($Obj) {
    $arr = $null
    if ($Obj -is [array]) { $arr = $Obj }
    else {
        foreach ($p in $Obj.PSObject.Properties) { if ($p.Value -is [array] -and $p.Value.Count -gt 0) { $arr = $p.Value; break } }
    }
    if (-not $arr) { return @() }
    return @($arr | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties['id'] })
}

# ================================================================= screens
function Invoke-QuickGrab {
    Show-RGBanner
    Write-C '   QUICK GRAB  -  3 steps, no files to save' 'Cyan'
    Write-RGRule
    Write-Info 'Make sure you are logged in to resume.io in your browser.'
    Write-Info 'Chrome / Edge: just press Ctrl+A then Ctrl+C on each page that opens.'
    Write-Info 'Firefox: click "Raw Data" first, then Ctrl+A, Ctrl+C.'
    Write-Host ''

    Write-C '   STEP 1/3 ' 'Magenta' -NoNewline; Write-C '  Opening your resume list...' 'White'
    Open-RGUrl "$($script:RG_ORIGIN)/api/app/resumes"
    $listJson = Wait-RGClipboardJson -Waiting '   Copy the page (Ctrl+A, Ctrl+C)' -Accept {
        param($o) (Get-RGResumeList $o).Count -gt 0 -or (Test-RGResumeDoc $o)
    }
    if (-not $listJson) { return }
    $listObj = ConvertFrom-RGJson $listJson

    # They may have copied a single resume directly - just render it.
    if (Test-RGResumeDoc $listObj) {
        Write-Ok 'Got a full resume - rendering it.'
        $null = Convert-RGJson -JsonText $listJson -Label 'clipboard'
        Wait-RGKey; return
    }

    $list = Get-RGResumeList $listObj
    Write-Ok ("Found {0} resume(s)." -f $list.Count)
    $chosen = $list[0]
    if ($list.Count -gt 1) {
        $items = @(); $n = 0
        foreach ($r in ($list | Select-Object -First 9)) {
            $n++
            $label = @($r.PSObject.Properties['name'], $r.PSObject.Properties['title']) | Where-Object { $_ -and $_.Value } | Select-Object -First 1
            $label = if ($label) { [string]$label.Value } else { "Resume $($r.id)" }
            $hint = ''
            foreach ($k in 'updatedAt', 'updated_at') { if ($r.PSObject.Properties[$k]) { $hint = 'updated ' + ([string]$r.$k).Substring(0, [Math]::Min(10, ([string]$r.$k).Length)) } }
            $items += @{ Key = [string]$n; Label = $label; Hint = $hint; Obj = $r }
        }
        Write-Host ''
        $pick = Show-RGMenu -Title 'Which resume?' -Items $items
        $hit = $items | Where-Object { $_.Key -eq $pick } | Select-Object -First 1
        if (-not $hit) { return }
        $chosen = $hit.Obj
    }
    $id = [string]$chosen.id

    Write-Host ''
    Write-C '   STEP 2/3 ' 'Magenta' -NoNewline; Write-C "  Opening resume $id..." 'White'
    Open-RGUrl "$($script:RG_ORIGIN)/api/app/resumes/$id"
    $docJson = Wait-RGClipboardJson -Waiting '   Copy this page too (Ctrl+A, Ctrl+C)' -Accept {
        param($o) (Test-RGResumeDoc $o)
    }
    if (-not $docJson) { return }

    Write-Host ''
    Write-C '   STEP 3/3 ' 'Magenta' -NoNewline; Write-C '  Building your PDF' 'White'
    $null = Convert-RGJson -JsonText $docJson -Label "resume $id"
    Wait-RGKey
}

function Invoke-ConvertFiles {
    Show-RGBanner
    Write-C '   CONVERT JSON FILE(S)' 'Cyan'; Write-RGRule
    $files = Select-RGFile -InitialDir (Get-DownloadsDir)
    if (-not $files -or $files.Count -eq 0) { Write-Warn 'Nothing selected.'; Wait-RGKey; return }
    $ok = 0
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { Write-Err "Not found: $f"; continue }
        Write-Host ''
        if (Convert-RGFile $f -NoOpen:($files.Count -gt 1)) { $ok++ }
    }
    Write-Host ''; Write-Ok "$ok of $($files.Count) converted."
    Wait-RGKey
}

function Invoke-ConvertClipboard {
    Show-RGBanner
    Write-C '   CONVERT FROM CLIPBOARD' 'Cyan'; Write-RGRule
    $json = Get-JsonFromText (Get-RGClipboardText)
    if ($json -and (Test-RGResumeDoc (ConvertFrom-RGJson $json))) {
        $null = Convert-RGJson -JsonText $json -Label 'clipboard'
    } else {
        Write-Info 'Your clipboard has no resume JSON yet. Copy https://resume.io/api/app/resumes/<id>'
        $json = Wait-RGClipboardJson -Accept { param($o) Test-RGResumeDoc $o }
        if ($json) { $null = Convert-RGJson -JsonText $json -Label 'clipboard' }
    }
    Wait-RGKey
}

function Invoke-Batch {
    Show-RGBanner
    Write-C '   BATCH CONVERT A FOLDER' 'Cyan'; Write-RGRule
    $dir = Select-RGFolder 'Folder with resume.io JSON files' (Get-DownloadsDir)
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { Write-Warn 'No folder chosen.'; Wait-RGKey; return }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter *.json -File -Recurse -ErrorAction SilentlyContinue)
    $cands = @()
    foreach ($f in $files) {
        try { $j = Get-JsonFromText ([IO.File]::ReadAllText($f.FullName)); if ($j -and (Test-RGResumeDoc (ConvertFrom-RGJson $j))) { $cands += $f } } catch { }
    }
    if ($cands.Count -eq 0) { Write-Warn "No resume.io JSON files in $dir"; Wait-RGKey; return }
    Write-Ok "$($cands.Count) resume(s) found."
    $ok = 0; $n = 0
    foreach ($f in $cands) {
        $n++; Write-Host ''; Write-C ("   ({0}/{1}) {2}" -f $n, $cands.Count, $f.Name) 'White'
        if (Convert-RGFile $f.FullName -NoOpen) { $ok++ }
    }
    Write-Host ''; Write-Ok "$ok of $($cands.Count) converted into $((Get-RGSettings).OutputDir)"
    if ($ok -gt 0 -and (Read-RGYesNo 'Open the output folder?')) { Open-RGItem (Get-RGSettings).OutputDir }
    Wait-RGKey
}

function Invoke-WatchMode {
    param([switch]$Standalone)
    $settings = Get-RGSettings
    $folder = $settings.WatchFolder
    if (-not $Standalone) { Show-RGBanner }
    Write-C '   WATCH MODE' 'Cyan'; Write-RGRule
    Write-Info "Watching: $folder  (new .json files)"
    Write-Info 'Watching: your clipboard (copied resume JSON)'
    Write-Info 'Any resume.io JSON that shows up is converted automatically. Press Q or Esc to stop.'
    Write-Host ''
    $seen = @{}
    if (Test-Path -LiteralPath $folder) {
        Get-ChildItem -LiteralPath $folder -Filter *.json -File -ErrorAction SilentlyContinue | ForEach-Object { $seen[$_.FullName] = $_.LastWriteTimeUtc }
    }
    $lastClip = Get-RGClipboardText
    $count = 0
    while ($true) {
        if ($script:RG_Interactive -and [Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape' -or $k.KeyChar -eq 'q' -or $k.KeyChar -eq 'Q') { break }
        }
        if (Test-Path -LiteralPath $folder) {
            foreach ($f in (Get-ChildItem -LiteralPath $folder -Filter *.json -File -ErrorAction SilentlyContinue)) {
                if ($seen.ContainsKey($f.FullName) -and $seen[$f.FullName] -eq $f.LastWriteTimeUtc) { continue }
                $seen[$f.FullName] = $f.LastWriteTimeUtc
                Start-Sleep -Milliseconds 600   # let the browser finish writing
                try {
                    $j = Get-JsonFromText ([IO.File]::ReadAllText($f.FullName))
                    if ($j -and (Test-RGResumeDoc (ConvertFrom-RGJson $j))) {
                        Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline
                        Write-C ("   [{0:HH:mm:ss}] new file: {1}" -f (Get-Date), $f.Name) 'White'
                        if (Convert-RGJson -JsonText $j -Label $f.Name) {
                            $count++
                            if ($settings.DeleteJsonAfter) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
                        }
                        Write-Host ''
                    }
                } catch { }
            }
        }
        $clip = Get-RGClipboardText
        if ($clip -and $clip -ne $lastClip) {
            $lastClip = $clip
            $j = Get-JsonFromText $clip
            if ($j) {
                try {
                    if (Test-RGResumeDoc (ConvertFrom-RGJson $j)) {
                        Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline
                        Write-C ("   [{0:HH:mm:ss}] resume copied to clipboard" -f (Get-Date)) 'White'
                        if (Convert-RGJson -JsonText $j -Label 'clipboard') { $count++ }
                        Write-Host ''
                    }
                } catch { }
            }
        }
        if ($script:RG_Interactive) { Write-Host ("`r   watching... {0} converted so far  " -f $count) -ForegroundColor DarkMagenta -NoNewline }
        Start-Sleep -Milliseconds 800
    }
    Write-Host ''
    Write-Ok "Watch mode stopped. $count resume(s) converted."
    if (-not $Standalone) { Wait-RGKey }
}

function Invoke-History {
    Show-RGBanner
    Write-C '   RECENT PDFs' 'Cyan'; Write-RGRule
    $h = @(Get-RGHistory | Select-Object -First 9)
    if ($h.Count -eq 0) { Write-Info 'Nothing yet - convert your first resume!'; Wait-RGKey; return }
    $items = @(); $n = 0
    foreach ($e in $h) {
        $n++
        $exists = Test-Path -LiteralPath $e.output
        $label = [IO.Path]::GetFileName([string]$e.output)
        if ($label.Length -gt 34) { $label = $label.Substring(0, 33) + '~' }
        $hint = "{0}  {1}p{2}" -f $e.time, $e.pages, $(if ($exists) { '' } else { '  (moved)' })
        $items += @{ Key = [string]$n; Label = $label; Hint = $hint; Path = [string]$e.output }
    }
    $items += @{ Key = 'B'; Label = 'Back'; Hint = '' }
    $pick = Show-RGMenu -Title 'Open which PDF?' -Items $items
    $hit = $items | Where-Object { $_.Key -eq $pick -and $_.Path } | Select-Object -First 1
    if ($hit) {
        if (Test-Path -LiteralPath $hit.Path) { Show-RGInExplorer $hit.Path; Open-RGItem $hit.Path } else { Write-Warn 'That file was moved or deleted.'; Wait-RGKey }
    }
}

function Invoke-Settings {
    while ($true) {
        $s = Get-RGSettings
        Show-RGBanner
        Write-C '   SETTINGS' 'Cyan'; Write-RGRule
        $loc = if ($s.Locale) { $s.Locale } else { 'auto (from resume)' }
        $items = @(
            @{ Key = '1'; Label = 'Output folder';        Hint = [string]$s.OutputDir },
            @{ Key = '2'; Label = 'Open PDF after render'; Hint = $(if ($s.OpenAfterRender) { 'ON' } else { 'OFF' }) },
            @{ Key = '3'; Label = 'File name template';   Hint = [string]$s.FileNameTemplate },
            @{ Key = '4'; Label = 'Language override';    Hint = $loc },
            @{ Key = '5'; Label = 'Watch folder';         Hint = [string]$s.WatchFolder },
            @{ Key = '6'; Label = 'Delete JSON after watch'; Hint = $(if ($s.DeleteJsonAfter) { 'ON' } else { 'OFF' }) },
            @{ Key = 'R'; Label = 'Reset to defaults';    Hint = '' },
            @{ Key = 'B'; Label = 'Back';                 Hint = '' }
        )
        $pick = Show-RGMenu -Title 'Change what?' -Items $items
        Write-Host ''
        switch ($pick) {
            '1' { $d = Select-RGFolder 'Where should PDFs go?' $s.OutputDir; if ($d) { $s.OutputDir = $d } }
            '2' { $s.OpenAfterRender = -not $s.OpenAfterRender }
            '3' {
                Write-Info 'Placeholders: {name} {title} {doc} {date} {id} {token} {template}'
                $s.FileNameTemplate = Read-RGText 'New template' $s.FileNameTemplate
            }
            '4' { $s.Locale = Read-RGText 'Language code like en, de, fr, es, pt (blank = auto)' ''; }
            '5' { $d = Select-RGFolder 'Folder to watch' $s.WatchFolder; if ($d) { $s.WatchFolder = $d } }
            '6' { $s.DeleteJsonAfter = -not $s.DeleteJsonAfter }
            'R' { Remove-Item -LiteralPath (Get-RGPath 'settings') -Force -ErrorAction SilentlyContinue; continue }
            default { return }
        }
        Save-RGSettings $s
    }
}

function Invoke-Doctor {
    param([switch]$Standalone)
    if (-not $Standalone) { Show-RGBanner }
    Write-C '   DOCTOR' 'Cyan'; Write-RGRule
    $bad = 0
    Write-Ok ("ResumeGrabber {0}  |  PowerShell {1}  |  {2}" -f $script:RG_VERSION, $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
    Write-Info ("Home: {0}" -f (Get-RGHome))

    $node = Find-RGNode
    if ($node) { Write-Ok ("Node.js {0}  ({1})" -f (& $node --version), $node) }
    else { Write-Warn 'Node.js not installed yet - it will be downloaded automatically (portable, ~30 MB) on first render.' }

    $wdir = Get-RGPath 'worker'
    $files = @(Get-ChildItem -LiteralPath $wdir -File -ErrorAction SilentlyContinue)
    if ($files.Count) { Write-Ok ("Engine cache: {0} files, {1:N1} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB)) }
    else { Write-Info 'Engine cache: empty (downloads on first render)' }

    foreach ($u in @("$($script:RG_ORIGIN)/app/resumes", 'https://nodejs.org/dist/index.json', 'https://github.com')) {
        try { $null = Invoke-RGGet $u -Retries 1; Write-Ok "Reachable: $u" } catch { $bad++; Write-Err "Unreachable: $u" }
    }
    try {
        $b = Get-RGBundle -OnStatus { param($m) Write-Step $m }
        Write-Ok "resume.io engine: $($b.Entry)"
    } catch { $bad++; Write-Err $_.Exception.Message }

    $out = (Get-RGSettings).OutputDir
    try {
        if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
        $t = Join-Path $out '.rg-write-test'; Set-Content -LiteralPath $t -Value 'ok'; Remove-Item -LiteralPath $t -Force
        Write-Ok "Output folder writable: $out"
    } catch { $bad++; Write-Err "Can't write to $out" }

    Write-Host ''
    if ($bad -eq 0) { Write-Ok 'Everything looks good.' } else { Write-Warn "$bad problem(s) found. Log: $(Get-RGPath 'log')" }
    if (-not $Standalone) { Wait-RGKey }
}

function Invoke-RefreshEngine {
    Write-Step 'Clearing cached engine'
    Get-ChildItem -LiteralPath (Get-RGPath 'worker') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Get-RGPath 'cache') 'discovery.json') -Force -ErrorAction SilentlyContinue
    try { $b = Get-RGBundle -Force -OnStatus { param($m) Write-Step $m }; Write-Ok "Engine ready: $($b.Entry)" } catch { Write-Err $_.Exception.Message }
}

function Invoke-SelfUpdate {
    Write-Step "Downloading the latest ResumeGrabber from github.com/$($script:RG_REPO)"
    try {
        $installer = Invoke-RGGet "https://raw.githubusercontent.com/$($script:RG_REPO)/main/install.ps1"
        $tmp = Join-Path (Get-RGPath 'tmp') 'install.ps1'
        Write-Utf8NoBom $tmp $installer
        $exe = (Get-Process -Id $PID).Path
        & $exe -NoProfile -ExecutionPolicy Bypass -File $tmp -Quiet
        Write-Ok 'Updated. Restart ResumeGrabber to use the new version.'
    } catch { Write-Err "Update failed: $($_.Exception.Message)" }
}

function Show-RGHelp {
    Show-RGBanner
    Write-C '   HOW IT WORKS' 'Cyan'; Write-RGRule
    Write-Info '1. resume.io keeps your resume as JSON at  https://resume.io/api/app/resumes/<id>'
    Write-Info '2. ResumeGrabber feeds that JSON to resume.io''s own rendering engine,'
    Write-Info '   running locally inside a sandboxed, portable Node.js.'
    Write-Info '3. You get the exact same layout as the editor: every page, vector text, photo.'
    Write-Host ''
    Write-C '   COMMAND LINE' 'Cyan'; Write-RGRule
    Write-Info 'resumegrabber                       interactive app'
    Write-Info 'resumegrabber resume.json           convert one file'
    Write-Info 'resumegrabber a.json b.json -Out C:\CVs'
    Write-Info 'resumegrabber -Clipboard -Open      convert what you just copied'
    Write-Info 'resumegrabber -Watch                auto-convert downloads + clipboard'
    Write-Info 'resumegrabber -Doctor | -Update | -RefreshEngine | -Version'
    Write-Host ''
    Write-Info 'Tip: right-click any .json in Explorer -> "Convert with ResumeGrabber"'
    Write-Info '(Windows 11: Show more options). Your data only ever goes to resume.io.'
    Wait-RGKey
}

# ================================================================= entry
Set-RGConsole

if ($Version) { Write-Output "ResumeGrabber $($script:RG_VERSION)"; exit 0 }
if ($Doctor) { Invoke-Doctor -Standalone; exit 0 }
if ($Update) { Invoke-SelfUpdate; exit 0 }
if ($RefreshEngine) { Invoke-RefreshEngine; exit 0 }
if ($Watch) { Invoke-WatchMode -Standalone; exit 0 }

if ($Clipboard) {
    $json = Get-JsonFromText (Get-RGClipboardText)
    if (-not $json) { Write-Err 'Clipboard does not contain resume JSON.'; exit 1 }
    $r = Convert-RGJson -JsonText $json -Label 'clipboard' -OutPath $Out -OpenAfter:$Open -NoOpen:(-not $Open)
    if ($r) { exit 0 } else { exit 1 }
}

if ($Path -and $Path.Count -gt 0) {
    $targets = @()
    foreach ($p in $Path) {
        $resolved = @(Resolve-Path -Path $p -ErrorAction SilentlyContinue)
        if (-not $resolved) { Write-Err "Not found: $p"; continue }
        foreach ($r in $resolved) {
            if (Test-Path -LiteralPath $r.Path -PathType Container) {
                $targets += @(Get-ChildItem -LiteralPath $r.Path -Filter *.json -File | ForEach-Object FullName)
            } else { $targets += $r.Path }
        }
    }
    $fail = 0
    $outArg = $Out
    if ($targets.Count -gt 1 -and $Out -match '\.pdf$') { $outArg = Split-Path -Parent $Out }
    foreach ($t in $targets) {
        if (-not (Convert-RGFile $t -OutPath $outArg -OpenAfter:$Open -NoOpen:(-not $Open))) { $fail++ }
    }
    # Launched from Explorer's right-click menu: keep the window open so the result is readable.
    if ($env:RG_FROM_EXPLORER -eq '1') {
        if ($fail -eq 0 -and $targets.Count -gt 0) { Start-Sleep -Seconds 3 } else { Wait-RGKey 'Press any key to close' }
    }
    if ($fail -gt 0) { exit 1 } else { exit 0 }
}

# ---- interactive app
while ($true) {
    Show-RGBanner
    $s = Get-RGSettings
    $last = @(Get-RGHistory | Select-Object -First 1)
    if ($last.Count) { Write-Info ("Last PDF: {0}  ({1})" -f [IO.Path]::GetFileName([string]$last[0].output), $last[0].time); Write-Host '' }
    $choice = Show-RGMenu -Title 'What do you want to do?' -Items @(
        @{ Key = '1'; Label = 'Quick Grab (guided)';        Hint = 'easiest - browser + clipboard' },
        @{ Key = '2'; Label = 'Convert JSON file(s)';        Hint = 'pick one or many files' },
        @{ Key = '3'; Label = 'Convert from clipboard';      Hint = 'you already copied the JSON' },
        @{ Key = '4'; Label = 'Batch convert a folder';      Hint = 'every resume JSON inside' },
        @{ Key = '5'; Label = 'Watch mode';                  Hint = 'auto-convert as you download' },
        @{ Key = '6'; Label = 'Recent PDFs';                 Hint = 'reopen past conversions' },
        @{ Key = '7'; Label = 'Open output folder';          Hint = [string]$s.OutputDir },
        @{ Key = '8'; Label = 'Settings';                    Hint = 'folder, naming, language' },
        @{ Key = '9'; Label = 'Doctor';                      Hint = 'check everything works' },
        @{ Key = 'U'; Label = 'Update ResumeGrabber';        Hint = 'app + rendering engine' },
        @{ Key = 'H'; Label = 'Help';                        Hint = 'how it works, CLI usage' },
        @{ Key = 'Q'; Label = 'Quit';                        Hint = '' }
    )
    switch ($choice) {
        '1' { Invoke-QuickGrab }
        '2' { Invoke-ConvertFiles }
        '3' { Invoke-ConvertClipboard }
        '4' { Invoke-Batch }
        '5' { Invoke-WatchMode }
        '6' { Invoke-History }
        '7' { $d = $s.OutputDir; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; Open-RGItem $d }
        '8' { Invoke-Settings }
        '9' { Invoke-Doctor }
        'U' { Show-RGBanner; Invoke-SelfUpdate; Invoke-RefreshEngine; Wait-RGKey }
        'H' { Show-RGHelp }
        default { Write-Host ''; Write-C '   Bye!' 'Cyan'; exit 0 }
    }
}
