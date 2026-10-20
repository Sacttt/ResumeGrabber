# ResumeGrabber - PDF -> PNG using Windows' built-in PDF renderer (Windows.Data.Pdf, Windows 10+).
# Needs Windows PowerShell 5.1 (WinRT interop). No extra software.

$script:RG_WinRTReady = $false

function Initialize-RGWinRT {
    if ($script:RG_WinRTReady) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfPageRenderOptions,Windows.Data.Pdf,ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.InMemoryRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
    $script:RG_AsTaskOp = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $script:RG_AsTaskAction = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
    $script:RG_WinRTReady = $true
}

function Wait-RGOp($Operation, [type]$ResultType) {
    $task = $script:RG_AsTaskOp.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    try { [void]$task.Wait(-1) } catch { throw (Get-RGInnerError $_.Exception) }
    return $task.Result
}

function Get-RGInnerError($Ex) {
    while ($Ex.InnerException) { $Ex = $Ex.InnerException }
    return ("Windows PDF renderer: " + $Ex.Message)
}

function Wait-RGAction($Action) {
    $task = $script:RG_AsTaskAction.Invoke($null, @($Action))
    try { [void]$task.Wait(-1) } catch { throw (Get-RGInnerError $_.Exception) }
}

function ConvertTo-RGPagePngs {
    <# Renders each PDF page to a PNG file. Returns the list of PNG paths. #>
    param([Parameter(Mandatory)][string]$PdfPath, [Parameter(Mandatory)][string]$OutDir, [int]$Dpi = 220, [scriptblock]$OnStatus = { param($m) })
    Initialize-RGWinRT
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    # Load through a plain .NET stream (no StorageFile brokering needed).
    $pdfBytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($PdfPath))
    $netStream = New-Object IO.MemoryStream (, $pdfBytes)
    $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($netStream)
    $doc = Wait-RGOp ([Windows.Data.Pdf.PdfDocument]::LoadFromStreamAsync($ras)) ([Windows.Data.Pdf.PdfDocument])
    $scale = $Dpi / 96.0
    $out = @()
    for ($i = 0; $i -lt $doc.PageCount; $i++) {
        & $OnStatus ("Drawing page {0} of {1}" -f ($i + 1), $doc.PageCount)
        $page = $doc.GetPage([uint32]$i)
        try {
            $opts = New-Object Windows.Data.Pdf.PdfPageRenderOptions
            $opts.DestinationWidth = [uint32][math]::Round($page.Size.Width * $scale)
            $opts.DestinationHeight = [uint32][math]::Round($page.Size.Height * $scale)
            $mem = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
            Wait-RGAction ($page.RenderToStreamAsync($mem, $opts))
            $mem.Seek(0)
            $src = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($mem)
            $target = Join-Path $OutDir ("page-{0:D2}.png" -f ($i + 1))
            $fs = [IO.File]::Create($target)
            try { $src.CopyTo($fs) } finally { $fs.Dispose(); $src.Dispose(); $mem.Dispose() }
            $out += $target
        } finally { $page.Dispose() }
    }
    $ras.Dispose(); $netStream.Dispose()
    return $out
}

function Join-RGPngs {
    <# Stacks page images vertically into one PNG, with a soft gray gap between pages. #>
    param([Parameter(Mandatory)][string[]]$Pages, [Parameter(Mandatory)][string]$OutFile, [int]$Gap = 32)
    Add-Type -AssemblyName System.Drawing
    if ($Pages.Count -eq 1) { Copy-Item -LiteralPath $Pages[0] -Destination $OutFile -Force; return $OutFile }
    $imgs = @($Pages | ForEach-Object { [System.Drawing.Image]::FromFile($_) })
    try {
        $w = ($imgs | Measure-Object Width -Maximum).Maximum
        $h = ($imgs | Measure-Object Height -Sum).Sum + $Gap * ($imgs.Count + 1)
        $bmp = New-Object System.Drawing.Bitmap ([int]($w + 2 * $Gap)), ([int]$h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::FromArgb(255, 229, 231, 235))
            $g.InterpolationMode = 'HighQualityBicubic'
            $y = $Gap
            foreach ($im in $imgs) {
                $g.DrawImage($im, [int]($Gap + ($w - $im.Width) / 2), [int]$y, $im.Width, $im.Height)
                $y += $im.Height + $Gap
            }
        } finally { $g.Dispose() }
        $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    } finally { $imgs | ForEach-Object { $_.Dispose() } }
    return $OutFile
}
