# WifiGate - Home.ps1 : the single desktop file in "visible" mode. Big visible "disable Wi-Fi" button;
# the other options (unlock, settings, tests, recovery) open only after the password.
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
$created = $false
$script:instance = New-Object System.Threading.Mutex($true, 'Local\WifiGateHomeWindow', [ref]$created)
if (-not $created) { exit }

. (Join-Path $PSScriptRoot 'Ui.ps1')
. (Join-Path $PSScriptRoot 'Screens.ps1')

try {
    $form = New-HomeForm
    [void]$form.ShowDialog()
} catch {
    Write-Log "home window error: $($_.Exception.Message)"
    [void](Show-Message ("שגיאה בפתיחת החלון:`n" + $_.Exception.Message) 'WifiGate' 'OK' 'Warning')
}
