# Checks that converting a PDF to PNG leaves powershell.exe able to exit cleanly.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $root 'lib') 'Png.ps1')
$out = Join-Path ([IO.Path]::GetTempPath()) ('rg-png-' + [guid]::NewGuid().ToString('N'))
$p = ConvertTo-RGPagePngs -PdfPath (Join-Path $PSScriptRoot 'fixture-2pages.pdf') -OutDir $out -Dpi 150
Write-Host "made $(@($p).Count) png(s)"
Remove-Item -LiteralPath $out -Recurse -Force
exit 0
