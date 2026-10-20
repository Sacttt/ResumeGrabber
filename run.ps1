<#
  ResumeGrabber launcher - portable, nothing is installed.

      irm https://raw.githubusercontent.com/Sacttt/ResumeGrabber/main/run.ps1 | iex

  Downloads the app into a temporary folder, opens it, and deletes that folder when you close the app.
  Only the PNGs you create are kept.
#>
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $repo = 'Sacttt/ResumeGrabber'
    $branch = 'main'
    if ($env:RESUMEGRABBER_BRANCH) { $branch = $env:RESUMEGRABBER_BRANCH }

    if ($env:OS -ne 'Windows_NT') { Write-Host 'ResumeGrabber runs on Windows 10/11.' -ForegroundColor Red; return }

    Write-Host ''
    Write-Host '  ResumeGrabber' -ForegroundColor Cyan -NoNewline
    Write-Host '  -  resume.io to PNG, portable' -ForegroundColor DarkGray

    # Sweep leftovers from sessions that were killed before they could clean up (e.g. PC shut down).
    Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'ResumeGrabber-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-12) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $session = Join-Path $env:TEMP ('ResumeGrabber-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $session -Force | Out-Null
    $app = Join-Path $session 'app'

    try {
        $local = $null
        if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ResumeGrabber.ps1'))) { $local = $PSScriptRoot }
        if ($local) {
            Write-Host '  > Using local copy' -ForegroundColor DarkGray
            New-Item -ItemType Directory -Path $app -Force | Out-Null
            foreach ($i in 'ResumeGrabber.ps1', 'lib', 'engine', 'ui') { Copy-Item -LiteralPath (Join-Path $local $i) -Destination $app -Recurse }
        } else {
            Write-Host '  > Downloading app (temporary)' -ForegroundColor DarkGray
            $zip = Join-Path $session 'app.zip'
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $session 'x') -Force
            $inner = Get-ChildItem -LiteralPath (Join-Path $session 'x') -Directory | Select-Object -First 1
            Move-Item -LiteralPath $inner.FullName -Destination $app
            Remove-Item -LiteralPath (Join-Path $session 'x'), $zip -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host '  > Opening the app window...' -ForegroundColor DarkGray
        Write-Host '    Close the app when you are done - everything except your PNGs is deleted.' -ForegroundColor DarkGray
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $p = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
            '-File', "`"$(Join-Path $app 'ResumeGrabber.ps1')`"", '-SessionDir', "`"$session`""
        )
        if ($p.ExitCode -ne 0) { Write-Host "  App exited with code $($p.ExitCode)." -ForegroundColor Yellow }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Set-Location -LiteralPath $env:TEMP
        for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $session); $i++) {
            Remove-Item -LiteralPath $session -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $session) { Start-Sleep -Milliseconds 500 }
        }
        if (Test-Path -LiteralPath $session) { Write-Host "  Couldn't fully clean $session - it will be removed next time." -ForegroundColor Yellow }
        else { Write-Host '  Cleaned up. Nothing was left on your PC except your PNGs.' -ForegroundColor Green }
        Write-Host ''
    }
}
