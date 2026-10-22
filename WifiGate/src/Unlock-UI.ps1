# WifiGate - Unlock-UI.ps1 : main window. Password + one button = unlock; lock now; auto-lock timer;
# change password; daily lock. (Ctrl+Alt+P)

# Self-elevate (a UAC prompt appears once) because firewall/adapter changes need admin.
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
. (Join-Path $PSScriptRoot 'Ui.ps1')
. (Join-Path $PSScriptRoot 'Screens.ps1')

try {
    $form = New-MainForm
    [void]$form.ShowDialog()
} catch {
    Write-Log "main window error: $($_.Exception.Message)"
    [void](Show-Message ("שגיאה בפתיחת החלון:`n" + $_.Exception.Message) 'WifiGate' 'OK' 'Warning')
}
