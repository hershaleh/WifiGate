# Console.ps1 : one discreet terminal menu (English, neutral wording).
#   1 = open window (password)   2 = lock   3 = checks window   4 = recovery window
param([string]$Choice = '')

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Start-Window([string]$Script) {
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $PSScriptRoot $Script) + '"'))
}

function Show-Menu {
    try { $Host.UI.RawUI.WindowTitle = 'Terminal'; $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray' } catch { }
    Clear-Host
    Write-Host ''
    Write-Host '  Console'
    Write-Host '  -------'
    Write-Host ''
    Write-Host '  [1] Open'
    Write-Host '  [2] Close'
    Write-Host '  [3] Check'
    Write-Host '  [4] Restore'
    Write-Host '  [Q] Exit'
    Write-Host ''
    Write-Host -NoNewline '  > '
}

Show-Menu
if ($Choice) { $key = $Choice.Substring(0, 1) } else { $key = [string][Console]::ReadKey($true).KeyChar }
Write-Host $key
switch ($key.ToUpper()) {
    '1' { Start-Window 'Unlock-UI.ps1'; Write-Host '  OK' }
    '2' {
        try { Invoke-Lock; Write-Host '  Done' } catch { Write-Log "console lock error: $($_.Exception.Message)"; Write-Host '  Error'; Start-Sleep -Seconds 2 }
    }
    '3' { Start-Window 'Tests.ps1'; Write-Host '  OK' }
    '4' { Start-Window 'Recovery.ps1'; Write-Host '  OK' }
    default { }
}
Start-Sleep -Milliseconds 700
