# Offline self-tests. Run:  powershell -File tests\Run-Tests.ps1   (or pwsh)
# Uses a fake rendering worker, so it needs Node.js but no network.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('rg-test-' + [guid]::NewGuid().ToString('N'))
$env:RESUMEGRABBER_HOME = Join-Path $sandbox 'home'
. (Join-Path (Join-Path $root 'lib') 'Core.ps1')

$script:fail = 0; $script:pass = 0
function Assert($cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $name" -ForegroundColor Red; if ($env:GITHUB_ACTIONS) { Write-Host "::error::FAIL $name" } }
}

try {
    Initialize-RGDirs

    # --- JSON extraction from browser copy/paste
    Assert ((Get-JsonFromText "Pretty-print`n{""a"":1}") -eq '{"a":1}') 'extracts JSON after Chrome "Pretty-print" label'
    Assert ($null -eq (Get-JsonFromText 'hello')) 'rejects non-JSON'
    Assert ((Get-JsonFromText '[{"id":1}]') -eq '[{"id":1}]') 'keeps arrays'

    # --- document detection
    Assert (Test-RGResumeDoc (ConvertFrom-RGJson '{"id":1,"renderingToken":"x"}')) 'detects resume document'
    Assert (-not (Test-RGResumeDoc (ConvertFrom-RGJson '[{"id":1,"renderingToken":"x"}]'))) 'one-item list is not a document'
    Assert (-not (Test-RGResumeDoc (ConvertFrom-RGJson '{"foo":1}'))) 'random JSON is not a document'

    # --- naming
    $info = Get-RGResumeInfo '{"id":7,"renderingToken":"tok","personalDetails":{"firstName":"Ada","lastName":"Lovelace","jobTitle":"Analyst/Engineer"}}'
    Assert ($info.Name -eq 'Ada Lovelace') 'finds nested first/last name'
    Assert ((Get-RGOutputName $info '{name} - {title} - Resume') -eq 'Ada Lovelace - Analyst_Engineer - Resume') 'builds a safe file name'
    $anon = Get-RGResumeInfo '{"id":7,"renderingToken":"tok"}'
    Assert ((Get-RGOutputName $anon '{name} - {title} - Resume') -eq 'tok - Resume') 'falls back to the rendering token'

    # --- chunk discovery regexes
    $worker = 'x"workers/foo.123.js"y "workers/vendors." + {1:"0123456789abcdef0123",2:"abcdefabcdefabcdefab"}[e] })'
    $chunks = Get-RGChunkNames $worker
    Assert (($chunks -contains 'foo.123.js') -and ($chunks -contains 'vendors.0123456789abcdef0123.js')) 'finds worker chunks'

    # --- end-to-end render with a fake worker
    if (Find-RGNode) {
        $wdir = Get-RGPath 'worker'
        Set-Content -LiteralPath (Join-Path $wdir 'rendering.test.js') -Encoding ASCII -Value @'
self.onmessage = (e) => {
  const pdf = "%PDF-1.4\n<</Type /Page>>\n<</Type /Page>>\n<</Type /Pages>>\n%%EOF";
  self.postMessage({ success: true, result: new TextEncoder().encode(pdf) });
};
'@
        Write-Utf8NoBom (Join-Path (Get-RGPath 'cache') 'discovery.json') (@{ entry = 'rendering.test.js'; checked = (Get-Date).ToString('o') } | ConvertTo-Json)
        Write-Utf8NoBom (Join-Path (Get-RGPath 'config') 'en.json') '{}'
        $out = Join-Path $sandbox 'out'
        $r = Invoke-RGRender -JsonText '{"id":1,"renderingToken":"abc","locale":"en"}' -OutPath $out
        Assert ((Test-Path -LiteralPath $r.Output) -and $r.Pages -eq 2) 'renders a 2-page PDF through the engine'
    } else {
        Write-Host '  SKIP  end-to-end render (Node.js not installed)' -ForegroundColor Yellow
    }

    if ($env:OS -eq 'Windows_NT') {
        # --- the window's XAML loads
        Add-Type -AssemblyName PresentationFramework
        $xaml = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'ui') 'MainWindow.xaml'))
        $win = [Windows.Markup.XamlReader]::Parse($xaml)
        $outside = [regex]::Replace($xaml, '(?s)<ControlTemplate.*?</ControlTemplate>', '')
        $names = [regex]::Matches($outside, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        $missing = @($names | Where-Object { -not $win.FindName($_) })
        Assert ($missing.Count -eq 0) ("window XAML parses and every named element exists " + ($missing -join ','))

        # --- PDF -> PNG with Windows' renderer (needs Windows PowerShell 5.1)
        if ($PSVersionTable.PSVersion.Major -le 5) {
            . (Join-Path (Join-Path $root 'lib') 'Png.ps1')
            $pdf = Join-Path $PSScriptRoot 'fixture-2pages.pdf'
            $pngs = @(ConvertTo-RGPagePngs -PdfPath $pdf -OutDir (Join-Path $sandbox 'png') -Dpi 96)
            Assert ($pngs.Count -eq 2) 'renders each PDF page to PNG'
            $joined = Join-RGPngs -Pages $pngs -OutFile (Join-Path $sandbox 'all.png')
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($joined)
            Assert ($img.Height -gt 1584 -and $img.Width -ge 816) 'stacks pages into one image'
            $img.Dispose()
        }
    }
} catch {
    $script:fail++
    $msg = "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber) in $($_.InvocationInfo.ScriptName)"
    Write-Host "  ERROR $msg" -ForegroundColor Red
    if ($env:GITHUB_ACTIONS) { Write-Host "::error::$($PSVersionTable.PSVersion) $msg" }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n  {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
