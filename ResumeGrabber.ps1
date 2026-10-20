<#
.SYNOPSIS
    ResumeGrabber - portable app that turns your resume.io resume into a PNG.

.DESCRIPTION
    Nothing is installed. Everything (portable Node.js, resume.io's renderer, temp files) lives in a
    temporary session folder that is deleted when the window closes. Only your PNG stays.

    Normally started by run.ps1:
        irm https://raw.githubusercontent.com/Sacttt/ResumeGrabber/main/run.ps1 | iex
#>
param([string]$SessionDir)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'ResumeGrabber is a Windows app.' }
if ($PSVersionTable.PSVersion.Major -gt 5 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    # WPF needs STA and the PDF->PNG step needs Windows PowerShell 5.1 (WinRT): relaunch there.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    if ($SessionDir) { $argList += @('-SessionDir', "`"$SessionDir`"") }
    Start-Process -FilePath $ps -ArgumentList $argList -WindowStyle Hidden -Wait
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
trap {
    try { [void][Windows.MessageBox]::Show("ResumeGrabber hit an error:`n`n$($_.Exception.Message)", 'ResumeGrabber', 'OK', 'Error') } catch { }
    break
}

$Root = $PSScriptRoot
$OwnsSession = $false
if (-not $SessionDir) {
    $SessionDir = Join-Path $env:TEMP ('ResumeGrabber-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $OwnsSession = $true
}
if (-not (Test-Path -LiteralPath $SessionDir)) { New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null }
$env:RESUMEGRABBER_HOME = Join-Path $SessionDir 'data'

. (Join-Path (Join-Path $Root 'lib') 'Core.ps1')
Initialize-RGDirs

# ======================================================================= window
$xaml = [IO.File]::ReadAllText((Join-Path (Join-Path $Root 'ui') 'MainWindow.xaml'))
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$W = @{}
foreach ($m in [regex]::Matches($xaml, 'x:Name="([^"]+)"')) { $W[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }

$UI = @{
    Json = $null; Info = $null; JsonHash = ''; RenderedHash = ''
    Ready = $false; PendingRender = $false
    LastClip = ''; Saved = 0; LastPng = $null; LastFiles = @()
    OutDir = (Get-DownloadsDir); Tick = 0
}
$script:Job = $null

$Brush = @{
    Accent = [Windows.Media.BrushConverter]::new().ConvertFrom('#4CC2FF')
    Green  = [Windows.Media.BrushConverter]::new().ConvertFrom('#6CCB5F')
    Red    = [Windows.Media.BrushConverter]::new().ConvertFrom('#FF6B6B')
    Yellow = [Windows.Media.BrushConverter]::new().ConvertFrom('#FCE100')
    DoneBg = [Windows.Media.BrushConverter]::new().ConvertFrom('#16301F')
}
$IconFont = New-Object Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'

# ======================================================================= helpers
function Set-Status([string]$Text, [string]$Kind = 'info') {
    $W.StatusText.Text = $Text
    switch ($Kind) {
        'ok'    { $W.StatusIcon.Text = [string][char]0xE73E; $W.StatusIcon.Foreground = $Brush.Green }
        'error' { $W.StatusIcon.Text = [string][char]0xE783; $W.StatusIcon.Foreground = $Brush.Red }
        'warn'  { $W.StatusIcon.Text = [string][char]0xE7BA; $W.StatusIcon.Foreground = $Brush.Yellow }
        'busy'  { $W.StatusIcon.Text = [string][char]0xE895; $W.StatusIcon.Foreground = $Brush.Accent }
        default { $W.StatusIcon.Text = [string][char]0xE946; $W.StatusIcon.Foreground = $Brush.Accent }
    }
}

function Set-StepDone([int]$N, [string]$Text) {
    $glyph = $W["Step${N}Glyph"]; $num = $W["Step${N}Num"]
    $glyph.FontFamily = $IconFont; $glyph.Text = [string][char]0xE73E; $glyph.Foreground = $Brush.Green
    $num.Background = $Brush.DoneBg
    if ($Text) { $W["Step${N}Text"].Text = $Text }
}

function Get-Dpi {
    if ($W.Q150.IsChecked) { return 150 }
    if ($W.Q300.IsChecked) { return 300 }
    return 220
}

function Get-Layout {
    if ($W.LayoutPages.IsChecked) { return 'pages' }
    if ($W.LayoutBoth.IsChecked) { return 'both' }
    return 'one'
}

function Update-Cards {
    $W.CardOutTitle.Text = Split-Path -Leaf $UI.OutDir
    $W.CardOutSub.Text = $UI.OutDir
    $W.OutDirText.Text = $UI.OutDir
    $q = switch (Get-Dpi) { 150 { 'Standard' } 300 { 'Print' } default { 'High' } }
    $W.CardFmtTitle.Text = "PNG - $q"
    $l = switch (Get-Layout) { 'pages' { 'one PNG per page' } 'both' { 'combined + per page' } default { 'all pages in one image' } }
    $pdf = ''; if ($W.AlsoPdfChk.IsChecked) { $pdf = ' + PDF' }
    $W.CardFmtSub.Text = "{0} DPI, {1}{2}" -f (Get-Dpi), $l, $pdf
}

function Get-ClipText {
    try { if ([Windows.Clipboard]::ContainsText()) { return [Windows.Clipboard]::GetText() } } catch { }
    return ''
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) } finally { $sha.Dispose() }
}

function Show-ResumeList($List) {
    $W.ResumeList.Children.Clear()
    foreach ($r in $List) {
        $title = $null
        foreach ($k in 'name', 'title') { if (-not $title -and $r.PSObject.Properties[$k] -and $r.$k) { $title = [string]$r.$k } }
        if (-not $title) { $title = "Resume $($r.id)" }
        $sub = "ID $($r.id)"
        foreach ($k in 'updatedAt', 'updated_at') {
            if ($r.PSObject.Properties[$k] -and $r.$k) { $d = [string]$r.$k; $sub = 'Updated ' + $d.Substring(0, [Math]::Min(10, $d.Length)) }
        }
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $window.FindResource('Btn')
        $btn.Margin = '0,6,10,4'; $btn.Padding = '16,10'; $btn.MinWidth = 210
        $btn.HorizontalContentAlignment = 'Left'
        $btn.Tag = [string]$r.id
        $sp = New-Object Windows.Controls.StackPanel
        $sp.HorizontalAlignment = 'Left'
        $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $title; $t1.FontWeight = 'SemiBold'; $t1.FontSize = 15
        $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = $sub; $t2.FontSize = 12; $t2.Foreground = $window.FindResource('Sub')
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
        $btn.Content = $sp
        $btn.Add_Click({
            param($s, $e)
            Start-Process ("https://resume.io/api/app/resumes/" + $s.Tag)
            $W.Step3Text.Text = 'Now press Ctrl+A, Ctrl+C on the page that just opened.'
            Set-Status "Opened resume $($s.Tag) - copy that page (Ctrl+A, Ctrl+C)." 'busy'
        })
        [void]$W.ResumeList.Children.Add($btn)
    }
}

function Set-Detected([string]$Json, [string]$Source) {
    $info = Get-RGResumeInfo $Json
    $UI.Json = $Json; $UI.Info = $info; $UI.JsonHash = Get-TextHash $Json
    $name = $info.Name; if (-not $name) { $name = $info.DocName }; if (-not $name) { $name = 'Your resume' }
    $W.DetectedName.Text = $name
    $bits = @($info.Title, $(if ($info.Template) { "template: $($info.Template)" }), $(if ($info.Locale) { "language: $($info.Locale)" })) | Where-Object { $_ }
    $W.DetectedSub.Text = ($bits -join '   |   ')
    $W.DetectedCard.Visibility = 'Visible'
    $W.CreateBtn.IsEnabled = $true
    Set-StepDone 1; Set-StepDone 2; Set-StepDone 3 'Got it!'
    Set-Status "Resume found: $name" 'ok'
    return $true
}

function Receive-JsonText([string]$Text, [string]$Source, [switch]$UserAction) {
    $json = Get-JsonFromText $Text
    if (-not $json) {
        if ($UserAction) { Set-Status 'That is not JSON. Copy the whole resume.io page (Ctrl+A, Ctrl+C).' 'warn' }
        return
    }
    $obj = ConvertFrom-RGJson $json
    if (Test-RGResumeDoc $obj) {
        [void](Set-Detected $json $Source)
        $isNew = ((Get-TextHash $json) -ne $UI.RenderedHash)
        if ($UserAction -or ($W.AutoCreateChk.IsChecked -and $isNew)) { Request-Render }
        return
    }
    $list = @()
    if ($obj -is [array]) { $list = $obj } else { foreach ($p in $obj.PSObject.Properties) { if ($p.Value -is [array]) { $list = $p.Value; break } } }
    $list = @($list | Where-Object { $_ -is [Management.Automation.PSCustomObject] -and $_.PSObject.Properties['id'] })
    if ($list.Count -gt 0) {
        Show-ResumeList $list
        Set-StepDone 1
        $W.Step2Text.Text = "Found $($list.Count) resume(s). Click the one you want - it opens in your browser."
        Set-Status "Found $($list.Count) resume(s). Pick one in step 2." 'ok'
        if ($list.Count -eq 1) {
            Start-Process ("https://resume.io/api/app/resumes/" + $list[0].id)
            Set-StepDone 2 'Only one resume - opened it for you.'
            $W.Step3Text.Text = 'Now press Ctrl+A, Ctrl+C on the page that just opened.'
        }
        return
    }
    if ($UserAction) { Set-Status "This JSON isn't a resume.io resume." 'warn' }
}

# ======================================================================= background jobs
$JobScript = {
    param($Root, $DataHome, $Kind, $P, $Sync)
    $ErrorActionPreference = 'Stop'
    $env:RESUMEGRABBER_HOME = $DataHome
    try {
        . (Join-Path (Join-Path $Root 'lib') 'Core.ps1')
        . (Join-Path (Join-Path $Root 'lib') 'Png.ps1')
        $st = { param($m) $Sync.Status = $m }
        if ($Kind -eq 'prepare') {
            $Sync.Phase = 'node'
            $node = Get-RGNode -OnStatus $st
            $Sync.Node = $node
            $Sync.NodeVer = [string](& $node --version)
            $Sync.Phase = 'engine'
            $b = Get-RGBundle -OnStatus $st
            $Sync.Engine = $b.Entry
            $Sync.Offline = $b.Offline
        } else {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $tmp = Get-RGPath 'tmp'
            $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
            $pdf = Join-Path $tmp "resume-$id.pdf"
            $null = Invoke-RGRender -JsonText $P.Json -OutPath $pdf -Locale $P.Locale -OnStatus $st
            $pages = @(ConvertTo-RGPagePngs -PdfPath $pdf -OutDir (Join-Path $tmp "pages-$id") -Dpi $P.Dpi -OnStatus $st)
            & $st 'Saving PNG'
            $combined = Join-Path $tmp "combined-$id.png"
            $null = Join-RGPngs -Pages $pages -OutFile $combined

            if (-not (Test-Path -LiteralPath $P.OutDir)) { New-Item -ItemType Directory -Path $P.OutDir -Force | Out-Null }
            $base = Get-RGOutputName (Get-RGResumeInfo $P.Json) '{name} - {title} - Resume'
            $files = @(); $primary = $null
            if ($P.Layout -ne 'pages' -or $pages.Count -eq 1) {
                $target = Get-UniquePath (Join-Path $P.OutDir "$base.png")
                Copy-Item -LiteralPath $combined -Destination $target
                $files += $target; $primary = $target
            }
            if ($P.Layout -ne 'one' -and $pages.Count -gt 1) {
                for ($i = 0; $i -lt $pages.Count; $i++) {
                    $target = Get-UniquePath (Join-Path $P.OutDir ("{0} - Page {1}.png" -f $base, ($i + 1)))
                    Copy-Item -LiteralPath $pages[$i] -Destination $target
                    $files += $target
                    if (-not $primary) { $primary = $target }
                }
            }
            if ($P.AlsoPdf) {
                $target = Get-UniquePath (Join-Path $P.OutDir "$base.pdf")
                Copy-Item -LiteralPath $pdf -Destination $target
                $files += $target
            }
            $Sync.Result = @{ Primary = $primary; Files = $files; Preview = $combined; Pages = $pages.Count; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        }
    } catch {
        $Sync.Error = $_.Exception.Message
    } finally {
        $Sync.Done = $true
    }
}

function Start-RGJob([string]$Kind, [hashtable]$Params = @{}) {
    $sync = [hashtable]::Synchronized(@{ Status = ''; Done = $false; Error = $null; Result = $null; Phase = '' })
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($JobScript).AddArgument($Root).AddArgument($env:RESUMEGRABBER_HOME).AddArgument($Kind).AddArgument($Params).AddArgument($sync)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Sync = $sync; Kind = $Kind }
    $W.Busy.Visibility = 'Visible'
}

function Request-Render {
    if (-not $UI.Json) { Set-Status 'Copy or open a resume first.' 'warn'; return }
    if ($script:Job -and $script:Job.Kind -eq 'render') { return }
    if (-not $UI.Ready) {
        $UI.PendingRender = $true
        Set-Status 'Will create your PNG as soon as the renderer is ready...' 'busy'
        return
    }
    $W.CreateBtn.IsEnabled = $false; $W.DetectedCreateBtn.IsEnabled = $false
    Set-Status 'Creating your PNG...' 'busy'
    $UI.RenderedHash = $UI.JsonHash
    Start-RGJob 'render' @{
        Json = $UI.Json; Locale = $W.LocaleBox.Text.Trim(); Dpi = (Get-Dpi); Layout = (Get-Layout)
        OutDir = $UI.OutDir; AlsoPdf = [bool]$W.AlsoPdfChk.IsChecked
    }
}

function Show-Preview([string]$Path, $Result) {
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'
    $bmp.CreateOptions = 'IgnoreImageCache'
    $bmp.UriSource = New-Object Uri $Path
    $bmp.EndInit(); $bmp.Freeze()
    $W.PreviewImage.Source = $bmp
    $W.PreviewEmpty.Visibility = 'Collapsed'
    $W.PreviewActions.IsEnabled = $true
    $W.PreviewPath.Text = "{0}   -   {1} page(s), {2}s" -f $Result.Primary, $Result.Pages, $Result.Seconds
    $W.PreviewBadge.Visibility = 'Visible'
    $W.PreviewBadgeText.Text = [string]$Result.Pages
    $W.NavPreview.IsChecked = $true
}

function Complete-Job {
    $j = $script:Job; $script:Job = $null
    try { [void]$j.PS.EndInvoke($j.Handle) } catch { }
    $j.PS.Dispose(); $j.RS.Dispose()
    $W.Busy.Visibility = 'Collapsed'
    $s = $j.Sync
    if ($j.Kind -eq 'prepare') {
        if ($s.Error) {
            $W.CardNodeTitle.Text = 'Problem'; $W.CardEngineTitle.Text = 'Not ready'
            $W.CardEngineSub.Text = 'see status bar'
            Set-Status "Couldn't get ready: $($s.Error)  (check your internet, then reopen the app)" 'error'
            return
        }
        $UI.Ready = $true
        $W.CardNodeTitle.Text = "Node.js $($s.NodeVer)"
        $where = 'temporary copy'; if ($s.Node -notlike "$SessionDir*") { $where = 'already on this PC' }
        $W.CardNodeSub.Text = $where
        $W.CardEngineTitle.Text = 'Ready'
        $W.CardEngineSub.Text = $(if ($s.Offline) { 'cached engine' } else { "resume.io $($s.Engine)" })
        if ($UI.PendingRender) { $UI.PendingRender = $false; Request-Render }
        elseif (-not $UI.Json) { Set-Status 'Ready. Start with step 1 - or drop a resume .json on this window.' 'ok' }
        return
    }
    $W.CreateBtn.IsEnabled = $true; $W.DetectedCreateBtn.IsEnabled = $true
    if ($s.Error) {
        $UI.RenderedHash = ''
        Set-Status $s.Error 'error'
        return
    }
    $r = $s.Result
    $UI.Saved += @($r.Files | Where-Object { $_ -like '*.png' }).Count
    $W.SavedCount.Text = [string]$UI.Saved
    $UI.LastPng = $r.Primary; $UI.LastFiles = $r.Files
    Show-Preview $r.Preview $r
    Set-Status ("Saved {0}  ({1} page(s) in {2}s)" -f [IO.Path]::GetFileName($r.Primary), $r.Pages, $r.Seconds) 'ok'
    if ($W.OpenAfterChk.IsChecked) { Invoke-Item -LiteralPath $r.Primary }
}

# ======================================================================= wiring
$W.VersionText.Text = "v$($script:RG_VERSION)"
$W.AboutText.Text = "ResumeGrabber $($script:RG_VERSION)  -  temporary session folder: $SessionDir`nRenders with resume.io's own engine. Inspired by felipeall/resumeio-to-pdf (MIT)."
$W.Busy.Visibility = 'Collapsed'
Update-Cards

$W.MinBtn.Add_Click({ $window.WindowState = 'Minimized' })
$W.MaxBtn.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } })
$W.CloseBtn.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    if ($window.WindowState -eq 'Maximized') { $window.Content.Margin = '7'; $W.MaxBtn.Content = [string][char]0xE923 }
    else { $window.Content.Margin = '0'; $W.MaxBtn.Content = [string][char]0xE922 }
})

$pages = @{ NavGrab = 'PageGrab'; NavPreview = 'PagePreview'; NavSettings = 'PageSettings' }
foreach ($nav in $pages.Keys) {
    $W[$nav].Add_Checked({
        param($s, $e)
        foreach ($k in $pages.Keys) { $W[$pages[$k]].Visibility = $(if ($W[$k] -eq $s) { 'Visible' } else { 'Collapsed' }) }
    })
}

$W.OpenListBtn.Add_Click({
    Start-Process 'https://resume.io/api/app/resumes'
    $W.Step1Text.Text = 'Opened in your browser. Press Ctrl+A, then Ctrl+C on that page.'
    Set-Status 'Waiting for you to copy the resume list (Ctrl+A, Ctrl+C)...' 'busy'
})

$W.OpenFileBtn.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Resume JSON (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*'
    $dlg.InitialDirectory = $UI.OutDir
    if ($dlg.ShowDialog($window)) {
        try { Receive-JsonText ([IO.File]::ReadAllText($dlg.FileName)) 'file' -UserAction } catch { Set-Status $_.Exception.Message 'error' }
    }
})

$W.PasteBtn.Add_Click({
    $t = Get-ClipText
    $UI.LastClip = $t
    if (-not $t) { Set-Status 'Your clipboard is empty. Copy the resume page first.' 'warn'; return }
    try { Receive-JsonText $t 'clipboard' -UserAction } catch { Set-Status $_.Exception.Message 'error' }
})

$W.CreateBtn.Add_Click({ Request-Render })
$W.DetectedCreateBtn.Add_Click({ Request-Render })
$W.OpenOutBtn.Add_Click({ if (-not (Test-Path -LiteralPath $UI.OutDir)) { New-Item -ItemType Directory -Path $UI.OutDir -Force | Out-Null }; Invoke-Item -LiteralPath $UI.OutDir })

$W.BrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Where should your PNGs be saved?'
    $dlg.SelectedPath = $UI.OutDir
    if ($dlg.ShowDialog() -eq 'OK') { $UI.OutDir = $dlg.SelectedPath; Update-Cards }
})
foreach ($n in 'Q150', 'Q220', 'Q300', 'LayoutOne', 'LayoutPages', 'LayoutBoth') { $W[$n].Add_Checked({ Update-Cards }) }
$W.AlsoPdfChk.Add_Click({ Update-Cards })

$W.OpenPngBtn.Add_Click({ if ($UI.LastPng -and (Test-Path -LiteralPath $UI.LastPng)) { Invoke-Item -LiteralPath $UI.LastPng } })
$W.ShowFolderBtn.Add_Click({ if ($UI.LastPng) { Start-Process explorer.exe -ArgumentList "/select,`"$($UI.LastPng)`"" } })
$W.CopyImgBtn.Add_Click({
    if ($W.PreviewImage.Source) { [Windows.Clipboard]::SetImage($W.PreviewImage.Source); Set-Status 'Image copied - paste it anywhere.' 'ok' }
})
$W.SaveAsBtn.Add_Click({
    if (-not $UI.LastPng) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'PNG image (*.png)|*.png'
    $dlg.FileName = [IO.Path]::GetFileName($UI.LastPng)
    if ($dlg.ShowDialog($window)) { Copy-Item -LiteralPath $UI.LastPng -Destination $dlg.FileName -Force; Set-Status "Saved a copy to $($dlg.FileName)" 'ok' }
})

# drag & drop
$window.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $W.DropOverlay.Visibility = 'Visible' } })
$window.Add_DragLeave({ $W.DropOverlay.Visibility = 'Collapsed' })
$window.Add_Drop({
    param($s, $e)
    $W.DropOverlay.Visibility = 'Collapsed'
    $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    if ($files) {
        $f = @($files)[0]
        try { Receive-JsonText ([IO.File]::ReadAllText($f)) 'file' -UserAction } catch { Set-Status $_.Exception.Message 'error' }
    }
})

# timers: job polling + clipboard watching
$jobTimer = New-Object Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$jobTimer.Add_Tick({
    if (-not $script:Job) { return }
    $s = $script:Job.Sync
    if ($script:Job.Kind -eq 'prepare') {
        if ($s.Phase -eq 'node') { $W.CardNodeTitle.Text = 'Setting up...' }
        if ($s.Phase -eq 'engine') { $W.CardNodeTitle.Text = "Node.js $($s.NodeVer)"; $W.CardEngineTitle.Text = 'Downloading...' }
    }
    if ($s.Status -and $W.StatusText.Text -ne $s.Status -and ($script:Job.Kind -eq 'render' -or -not $UI.Json)) { Set-Status ($s.Status + '...') 'busy' }
    if ($s.Done) { Complete-Job }
})

$clipTimer = New-Object Windows.Threading.DispatcherTimer
$clipTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$clipTimer.Add_Tick({
    $UI.Tick++
    if ($UI.Tick % 5 -eq 0) {
        try {
            $bytes = (Get-ChildItem -LiteralPath $SessionDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $W.TempSize.Text = '{0:N0} MB' -f ($bytes / 1MB)
        } catch { }
    }
    $t = Get-ClipText
    if (-not $t -or $t -eq $UI.LastClip) { return }
    $UI.LastClip = $t
    if ($t.Length -gt 5MB -or $t.IndexOf('"id"') -lt 0) { return }
    try { Receive-JsonText $t 'clipboard' } catch { }
})

$window.Add_Loaded({
    $UI.LastClip = Get-ClipText   # ignore whatever was on the clipboard before the app opened
    Set-Status 'Getting ready - downloading the renderer into a temporary folder...' 'busy'
    Start-RGJob 'prepare'
    $jobTimer.Start(); $clipTimer.Start()
    $window.Activate()
})

$window.Add_Closing({
    $jobTimer.Stop(); $clipTimer.Stop()
    if ($script:Job) { try { $script:Job.PS.Stop() } catch { } }
    Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$SessionDir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
})

[void]$window.ShowDialog()

# ======================================================================= leave no trace
if ($script:Job) { try { $script:Job.PS.Dispose(); $script:Job.RS.Dispose() } catch { } }
Set-Location -LiteralPath $env:TEMP
$cleanTarget = $env:RESUMEGRABBER_HOME
if ($OwnsSession -or ($Root -like "$SessionDir*")) { $cleanTarget = $SessionDir }
for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $cleanTarget); $i++) {
    Remove-Item -LiteralPath $cleanTarget -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $cleanTarget) { Start-Sleep -Milliseconds 500 }
}
