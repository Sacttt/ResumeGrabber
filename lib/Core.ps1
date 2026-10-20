# ResumeGrabber - core engine (paths, settings, Node bootstrap, resume.io assets, rendering)
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Set-StrictMode -Version 2.0

$script:RG_VERSION    = '3.0.0'
$script:RG_REPO       = 'Sacttt/ResumeGrabber'
$script:RG_ORIGIN     = 'https://resume.io'
$script:RG_UA         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
$script:RG_MIN_NODE   = 18
$script:RG_DISCOVERY_TTL_HOURS = 6
$script:RG_IsWindows  = ($env:OS -eq 'Windows_NT')

# ---------------------------------------------------------------- paths
function Get-RGHome {
    if ($env:RESUMEGRABBER_HOME) { return $env:RESUMEGRABBER_HOME }
    if ($script:RG_IsWindows) { return (Join-Path $env:LOCALAPPDATA 'ResumeGrabber') }
    return (Join-Path $HOME '.resumegrabber')
}

function Get-RGPath([string]$Name) {
    $homeDir = Get-RGHome
    switch ($Name) {
        'home'     { return $homeDir }
        'node'     { return (Join-Path $homeDir 'node') }
        'cache'    { return (Join-Path $homeDir 'cache') }
        'worker'   { return (Join-Path (Join-Path $homeDir 'cache') 'worker') }
        'config'   { return (Join-Path (Join-Path $homeDir 'cache') 'config') }
        'tmp'      { return (Join-Path $homeDir 'tmp') }
        'settings' { return (Join-Path $homeDir 'settings.json') }
        'history'  { return (Join-Path $homeDir 'history.json') }
        'log'      { return (Join-Path $homeDir 'resumegrabber.log') }
    }
    throw "Unknown path '$Name'"
}

function Initialize-RGDirs {
    foreach ($n in 'home', 'cache', 'worker', 'config', 'tmp') {
        $p = Get-RGPath $n
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

function Write-RGLog([string]$Message) {
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath (Get-RGPath 'log') -Value $line -Encoding UTF8
    } catch { }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- settings
function Get-DefaultOutputDir {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = $HOME }
    return (Join-Path $docs 'ResumeGrabber')
}

function Get-DownloadsDir {
    if ($script:RG_IsWindows) {
        try {
            $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
            if ($v -and (Test-Path -LiteralPath $v)) { return $v }
        } catch { }
        return (Join-Path $env:USERPROFILE 'Downloads')
    }
    return (Join-Path $HOME 'Downloads')
}

function Get-RGSettings {
    $defaults = [ordered]@{
        OutputDir        = Get-DefaultOutputDir
        OpenAfterRender  = $true
        FileNameTemplate = '{name} - {title} - Resume'
        Locale           = ''
        WatchFolder      = Get-DownloadsDir
        DeleteJsonAfter  = $false
    }
    $path = Get-RGPath 'settings'
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($defaults.Contains($p.Name)) { $defaults[$p.Name] = $p.Value }
            }
        } catch { Write-RGLog "settings unreadable: $_" }
    }
    return $defaults
}

function Save-RGSettings($Settings) {
    Initialize-RGDirs
    Write-Utf8NoBom (Get-RGPath 'settings') ($Settings | ConvertTo-Json -Depth 5)
}

# ---------------------------------------------------------------- history
function Get-RGHistory {
    $path = Get-RGPath 'history'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
}

function Add-RGHistory($Entry) {
    $items = @($Entry) + @(Get-RGHistory | Select-Object -First 99)
    Write-Utf8NoBom (Get-RGPath 'history') (ConvertTo-Json -InputObject $items -Depth 5)
}

# ---------------------------------------------------------------- http
function Initialize-RGNet {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Invoke-RGGet {
    param([Parameter(Mandatory)][string]$Url, [string]$OutFile, [int]$Retries = 3)
    Initialize-RGNet
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        for ($i = 1; $i -le $Retries; $i++) {
            try {
                $req = @{ Uri = $Url; UseBasicParsing = $true; Headers = @{ 'User-Agent' = $script:RG_UA }; TimeoutSec = 60 }
                if ($OutFile) {
                    $part = "$OutFile.part"
                    Invoke-WebRequest @req -OutFile $part | Out-Null
                    Move-Item -LiteralPath $part -Destination $OutFile -Force
                    return $OutFile
                }
                $resp = Invoke-WebRequest @req
                $content = $resp.Content
                if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
                return [string]$content
            } catch {
                if ($i -eq $Retries) { throw "GET $Url failed: $($_.Exception.Message)" }
                Start-Sleep -Milliseconds (400 * $i)
            }
        }
    } finally { $ProgressPreference = $old }
}

# ---------------------------------------------------------------- Node.js (portable, no admin, no Docker)
function Get-NodeMajor([string]$Exe) {
    try {
        $v = (& $Exe --version 2>$null | Select-Object -First 1)
        if ($v -match '^v(\d+)\.') { return [int]$Matches[1] }
    } catch { }
    return 0
}

function Find-RGNode {
    $local = Get-RGPath 'node'
    $candidates = @()
    if ($script:RG_IsWindows) { $candidates += (Join-Path $local 'node.exe') } else { $candidates += (Join-Path (Join-Path $local 'bin') 'node') }
    if ($env:RESUMEGRABBER_NODE) { $candidates = @($env:RESUMEGRABBER_NODE) + $candidates }
    $onPath = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c) -and ((Get-NodeMajor $c) -ge $script:RG_MIN_NODE)) { return $c }
    }
    return $null
}

function Install-RGNode {
    param([scriptblock]$OnStatus = { param($m) })
    if (-not $script:RG_IsWindows) { throw "Please install Node.js $($script:RG_MIN_NODE)+ with your package manager." }
    Initialize-RGDirs
    $arch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $arch = 'arm64' }

    & $OnStatus 'Looking up the latest Node.js LTS'
    $index = Invoke-RGGet 'https://nodejs.org/dist/index.json' | ConvertFrom-Json
    $release = $index | Where-Object { $_.lts -and ($_.files -contains "win-$arch-zip") } | Select-Object -First 1
    if (-not $release) { throw 'Could not find a Node.js LTS build for this PC.' }
    $ver = $release.version
    $zipName = "node-$ver-win-$arch.zip"
    $base = "https://nodejs.org/dist/$ver"

    $tmp = Get-RGPath 'tmp'
    $zip = Join-Path $tmp $zipName
    & $OnStatus "Downloading portable Node.js $ver ($arch)"
    Invoke-RGGet "$base/$zipName" -OutFile $zip | Out-Null

    & $OnStatus 'Verifying checksum'
    $sums = Invoke-RGGet "$base/SHASUMS256.txt"
    $expected = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($zipName) } | Select-Object -First 1)
    if (-not $expected) { throw 'Checksum for Node.js not published.' }
    $expected = ($expected.Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Remove-Item -LiteralPath $zip -Force; throw 'Node.js download failed checksum verification.' }

    & $OnStatus 'Unpacking Node.js'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dest = Get-RGPath 'node'
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $za = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $za.Entries | Where-Object { $_.FullName -match '^[^/]+/node\.exe$' } | Select-Object -First 1
        if (-not $entry) { throw 'node.exe not found in the Node.js archive.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $dest 'node.exe'), $true)
    } finally { $za.Dispose() }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Write-RGLog "installed portable node $ver"
    return (Join-Path $dest 'node.exe')
}

function Get-RGNode {
    param([scriptblock]$OnStatus = { param($m) })
    $n = Find-RGNode
    if ($n) { return $n }
    return (Install-RGNode -OnStatus $OnStatus)
}

# ---------------------------------------------------------------- resume.io renderer assets
function Get-RGWorkerNameFromSite {
    $app = Invoke-RGGet "$($script:RG_ORIGIN)/app/resumes"
    $m = [regex]::Match($app, '/assets/js/builder-[a-f0-9]+\.js')
    if (-not $m.Success) { throw 'resume.io did not serve a builder bundle (site layout changed?)' }
    $builder = Invoke-RGGet ($script:RG_ORIGIN + $m.Value)

    $names = @{}; $hashes = @{}
    foreach ($x in [regex]::Matches($builder, '(\d+):"([a-z-]+)"'))      { $names[$x.Groups[1].Value]  = $x.Groups[2].Value }
    foreach ($x in [regex]::Matches($builder, '(\d+):"([a-f0-9]{16})"')) { $hashes[$x.Groups[1].Value] = $x.Groups[2].Value }
    $id = $names.Keys | Where-Object { $names[$_] -eq 'rendering-core' } | Select-Object -First 1
    if (-not $id -or -not $hashes.ContainsKey($id)) { throw 'builder bundle does not map a rendering-core chunk' }

    $core = Invoke-RGGet "$($script:RG_ORIGIN)/assets/chunk/rendering-core.$($hashes[$id]).js"
    $w = [regex]::Match($core, '"workers/(rendering\.[a-f0-9]+\.js)"')
    if (-not $w.Success) { throw 'rendering-core does not reference a worker' }
    return $w.Groups[1].Value
}

function Get-RGChunkNames([string]$Worker) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in [regex]::Matches($Worker, '"workers/([A-Za-z0-9_.-]+\.js)"')) { [void]$set.Add($x.Groups[1].Value) }
    $marker = $Worker.IndexOf('"workers/vendors."')
    if ($marker -ge 0) {
        $len = [Math]::Min(6000, $Worker.Length - $marker)
        $table = $Worker.Substring($marker, $len)
        $end = $table.IndexOf('})')
        if ($end -ge 0) { $table = $table.Substring(0, $end) }
        foreach ($x in [regex]::Matches($table, '"([a-f0-9]{20})"')) { [void]$set.Add("vendors.$($x.Groups[1].Value).js") }
    }
    return @($set)
}

function Save-RGAsset([string]$Name) {
    $dir = Get-RGPath 'worker'
    $path = Join-Path $dir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-RGGet "$($script:RG_ORIGIN)/assets/workers/$Name" -OutFile $path | Out-Null
    }
    return $path
}

function Get-RGBundle {
    <# Returns @{ Dir; Entry; Offline } - downloads resume.io's rendering worker + chunks into the cache. #>
    param([switch]$Force, [scriptblock]$OnStatus = { param($m) })
    Initialize-RGDirs
    $discFile = Join-Path (Get-RGPath 'cache') 'discovery.json'
    $disc = $null
    if (Test-Path -LiteralPath $discFile) { try { $disc = Get-Content -LiteralPath $discFile -Raw | ConvertFrom-Json } catch { } }

    $entry = $null; $offline = $false
    $fresh = $disc -and -not $Force -and ((Get-Date) - [datetime]$disc.checked).TotalHours -lt $script:RG_DISCOVERY_TTL_HOURS `
             -and (Test-Path -LiteralPath (Join-Path (Get-RGPath 'worker') $disc.entry))
    if ($fresh) {
        $entry = $disc.entry
    } else {
        & $OnStatus 'Locating resume.io rendering engine'
        try {
            $entry = Get-RGWorkerNameFromSite
            Write-Utf8NoBom $discFile (@{ entry = $entry; checked = (Get-Date).ToString('o') } | ConvertTo-Json)
        } catch {
            if ($disc -and (Test-Path -LiteralPath (Join-Path (Get-RGPath 'worker') $disc.entry))) {
                Write-RGLog "discovery failed, using cached engine: $_"
                $entry = $disc.entry; $offline = $true
            } else { throw "Unable to fetch the resume.io renderer: $_" }
        }
    }

    $workerPath = Join-Path (Get-RGPath 'worker') $entry
    if (-not (Test-Path -LiteralPath $workerPath)) { & $OnStatus 'Downloading rendering engine (~4 MB, first run only)' }
    Save-RGAsset $entry | Out-Null
    $workerSrc = [IO.File]::ReadAllText($workerPath)
    $chunks = Get-RGChunkNames $workerSrc
    $missing = @($chunks | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Get-RGPath 'worker') $_)) })
    $i = 0
    foreach ($c in $missing) {
        $i++
        & $OnStatus ("Downloading engine chunk {0}/{1}" -f $i, $missing.Count)
        Save-RGAsset $c | Out-Null
    }
    return @{ Dir = (Get-RGPath 'worker'); Entry = $entry; Offline = $offline }
}

function Get-RGRendererConfig([string]$Locale) {
    $safe = ($Locale -replace '[^A-Za-z0-9_-]', '')
    if (-not $safe) { $safe = 'en' }
    $cacheFile = Join-Path (Get-RGPath 'config') "$safe.json"
    try {
        $txt = Invoke-RGGet "$($script:RG_ORIGIN)/api/app/general/renderer-config/$safe"
        $null = $txt | ConvertFrom-Json   # validate
        Write-Utf8NoBom $cacheFile $txt
        return $txt
    } catch {
        if (Test-Path -LiteralPath $cacheFile) { return [IO.File]::ReadAllText($cacheFile) }
        if ($safe -ne 'en') { return (Get-RGRendererConfig 'en') }
        throw "Unable to fetch the renderer config: $_"
    }
}

# ---------------------------------------------------------------- resume JSON helpers
function Get-JsonFromText([string]$Text) {
    <# Pulls a JSON object/array out of text copied from a browser (tolerates "Pretty-print" labels etc). #>
    if (-not $Text) { return $null }
    $Text = $Text.Trim([char]0xFEFF).Trim()
    $start = $Text.IndexOfAny([char[]]'{[')
    if ($start -lt 0) { return $null }
    $close = if ($Text[$start] -eq '{') { '}' } else { ']' }
    $end = $Text.LastIndexOf($close)
    if ($end -le $start) { return $null }
    $candidate = $Text.Substring($start, $end - $start + 1)
    try { $null = ConvertFrom-RGJson $candidate; return $candidate } catch { return $null }
}

function ConvertFrom-RGJson([string]$Text) {
    # Keeps top-level arrays as arrays (PowerShell 7 would unroll a 1-item array).
    if ($PSVersionTable.PSVersion.Major -ge 7) { return ,($Text | ConvertFrom-Json -NoEnumerate) }
    return ,($Text | ConvertFrom-Json)
}

function Find-RGField($Obj, [string[]]$Keys, [int]$Depth = 0) {
    if ($null -eq $Obj -or $Depth -gt 4) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($k in $Keys) {
            $p = $Obj.PSObject.Properties[$k]
            if ($p -and $p.Value -is [string] -and $p.Value.Trim()) { return $p.Value.Trim() }
        }
        foreach ($p in $Obj.PSObject.Properties) {
            if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
                $r = Find-RGField $p.Value $Keys ($Depth + 1)
                if ($r) { return $r }
            }
        }
    }
    return $null
}

function Test-RGResumeDoc($Doc) {
    if ($Doc -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $names = @($Doc.PSObject.Properties.Name)
    return ($names -contains 'renderingToken') -or (($names -contains 'id') -and (($names -contains 'template') -or ($names -contains 'sections') -or ($names -contains 'blocks')))
}

function Get-RGResumeInfo([string]$JsonText) {
    $doc = ConvertFrom-RGJson $JsonText
    if ($doc -is [array]) { throw 'This is the resume LIST, not a single resume. Open /api/app/resumes/<id> instead.' }
    if (-not (Test-RGResumeDoc $doc)) { throw "This JSON doesn't look like a resume.io resume." }
    $first = Find-RGField $doc @('firstName', 'first_name')
    $last  = Find-RGField $doc @('lastName', 'last_name')
    $title = Find-RGField $doc @('jobTitle', 'job_title', 'position')
    $docName = Find-RGField $doc @('name', 'title')
    $name = (@($first, $last) | Where-Object { $_ }) -join ' '
    $locale = 'en'
    if ($doc.PSObject.Properties['locale'] -and $doc.locale) { $locale = [string]$doc.locale }
    $token = ''
    if ($doc.PSObject.Properties['renderingToken']) { $token = [string]$doc.renderingToken }
    $id = ''
    if ($doc.PSObject.Properties['id']) { $id = [string]$doc.id }
    $template = ''
    if ($doc.PSObject.Properties['template']) { $template = [string]$doc.template }
    return [pscustomobject]@{
        Name = $name; Title = $title; DocName = $docName; Locale = $locale
        Token = $token; Id = $id; Template = $template
    }
}

function ConvertTo-SafeFileName([string]$Name) {
    $bad = [IO.Path]::GetInvalidFileNameChars() + [char[]]'"<>|:*?\/'
    $clean = -join ($Name.ToCharArray() | ForEach-Object { if ($bad -contains $_ -or [int]$_ -lt 32) { '_' } else { $_ } })
    $clean = ($clean -replace '\s+', ' ' -replace '( - )+', ' - ').Trim(' ', '-', '.', '_')
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 120).Trim() }
    if (-not $clean) { $clean = 'resume' }
    return $clean
}

function Get-RGOutputName($Info, [string]$Template) {
    if (-not $Template) { $Template = '{name} - {title} - Resume' }
    $date = Get-Date -Format 'yyyy-MM-dd'
    $n = $Template.Replace('{name}', $Info.Name).Replace('{title}', $Info.Title).Replace('{doc}', $Info.DocName).
            Replace('{id}', $Info.Id).Replace('{token}', $Info.Token).Replace('{date}', $date).Replace('{template}', $Info.Template)
    $n = ConvertTo-SafeFileName $n
    if ($n -eq 'Resume' -or $n -eq 'resume') {
        $fallback = @($Info.DocName, $Info.Token, $Info.Id) | Where-Object { $_ } | Select-Object -First 1
        if ($fallback) { $n = ConvertTo-SafeFileName "$fallback - Resume" }
    }
    return $n
}

function Get-UniquePath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = Split-Path -Parent $Path
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [IO.Path]::GetExtension($Path)
    for ($i = 2; $i -lt 1000; $i++) {
        $p = Join-Path $dir "$stem ($i)$ext"
        if (-not (Test-Path -LiteralPath $p)) { return $p }
    }
    return $Path
}

function Get-PdfPageCount([string]$Path) {
    try {
        $txt = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
        return ([regex]::Matches($txt, '/Type\s*/Page(?![a-zA-Z])')).Count
    } catch { return 0 }
}

# ---------------------------------------------------------------- render
function Invoke-RGRender {
    <#
      Renders a resume.io JSON document into a PDF.
      -JsonText : raw JSON of https://resume.io/api/app/resumes/<id>
      -OutPath  : full .pdf path, or a folder (file name is generated)
    #>
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [string]$OutPath,
        [string]$Locale,
        [string]$SourceLabel = 'json',
        [scriptblock]$OnStatus = { param($m) },
        [scriptblock]$OnTick = { }
    )
    $settings = Get-RGSettings
    Initialize-RGDirs
    $info = Get-RGResumeInfo $JsonText
    if (-not $Locale) { $Locale = $settings.Locale }
    if (-not $Locale) { $Locale = $info.Locale }

    if (-not $OutPath) { $OutPath = $settings.OutputDir }
    if ($OutPath -notmatch '\.pdf$') {
        if (-not (Test-Path -LiteralPath $OutPath)) { New-Item -ItemType Directory -Path $OutPath -Force | Out-Null }
        $OutPath = Get-UniquePath (Join-Path $OutPath ((Get-RGOutputName $info $settings.FileNameTemplate) + '.pdf'))
    } else {
        $parent = Split-Path -Parent $OutPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }
    $OutPath = [IO.Path]::GetFullPath($OutPath)

    $node   = Get-RGNode -OnStatus $OnStatus
    $bundle = Get-RGBundle -OnStatus $OnStatus
    & $OnStatus "Fetching renderer config ($Locale)"
    $config = Get-RGRendererConfig $Locale

    $engine = Join-Path (Join-Path $PSScriptRoot '..') 'engine'
    $script = [IO.Path]::GetFullPath((Join-Path $engine 'render.mjs'))
    $payloadPath = Join-Path (Get-RGPath 'tmp') ("payload-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    # Build the payload by splicing raw JSON so the resume never round-trips through PowerShell objects.
    $payload = '{"document":' + $JsonText.Trim([char]0xFEFF) + ',"config":' + $config +
               ',"assetsDir":' + (ConvertTo-Json -InputObject ([string]$bundle.Dir) -Compress) +
               ',"entry":' + (ConvertTo-Json -InputObject ([string]$bundle.Entry) -Compress) +
               ',"host":' + (ConvertTo-Json -InputObject $script:RG_ORIGIN -Compress) + '}'
    Write-Utf8NoBom $payloadPath $payload

    & $OnStatus 'Rendering every page with resume.io''s own engine'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = ('"{0}" "{1}" "{2}"' -f $script, $payloadPath, $OutPath)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $proc = [Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        while (-not $proc.WaitForExit(90)) {
            & $OnTick
            if ($sw.Elapsed.TotalSeconds -gt 150) { try { $proc.Kill() } catch { }; throw 'Rendering timed out.' }
        }
        $proc.WaitForExit()
        $stderr = $errTask.Result
        $null = $outTask.Result
        if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutPath)) {
            Write-RGLog "render failed: $stderr"
            $lines = @($stderr -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\[engine\]' })
            $errLine = $lines | Where-Object { $_ -match '^\s*[A-Za-z]*Error' } | Select-Object -First 1
            if (-not $errLine) { $errLine = $lines | Select-Object -First 1 }
            if (-not $errLine) { $errLine = 'the engine produced no output' }
            throw "Render failed: $($errLine.Trim())"
        }
    } finally {
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
    }
    $sw.Stop()

    $result = [pscustomobject]@{
        Output  = $OutPath
        Pages   = Get-PdfPageCount $OutPath
        SizeKB  = [math]::Round((Get-Item -LiteralPath $OutPath).Length / 1KB, 1)
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Name    = $info.Name
        Title   = $info.Title
        Offline = $bundle.Offline
    }
    Add-RGHistory ([pscustomobject]@{
        time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); output = $OutPath; pages = $result.Pages
        name = $info.Name; title = $info.Title; source = $SourceLabel
    })
    Write-RGLog "rendered $OutPath ($($result.Pages) pages)"
    return $result
}
