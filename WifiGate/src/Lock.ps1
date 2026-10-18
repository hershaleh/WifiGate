# WifiGate - Lock.ps1 : locks Wi-Fi immediately, no UI (hotkey Ctrl+Alt+X).
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
try { Invoke-Lock } catch { Write-Log "lock error: $($_.Exception.Message)"; exit 1 }
