# WifiGate - Recovery.ps1 : opens Wi-Fi using the password OR the recovery code,
# and optionally removes WifiGate completely.
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
. (Join-Path $PSScriptRoot 'Ui.ps1')

$secret = Read-SecretDialog 'שחזור: הזינו את הסיסמה או את קוד השחזור.'
if ($null -eq $secret) { exit }

try { $r = Invoke-Recovery $secret } catch { $r = New-Result $false ("שגיאה: " + $_.Exception.Message) }
if (-not $r.Ok) { [void](Show-Message $r.Message 'WifiGate' 'OK' 'Warning'); exit 1 }

$ans = Show-Message ("Wi-Fi נפתח.`n`nהחסימה תחזור באתחול הבא או בהתחברות הבאה, כל עוד WifiGate מותקן.`n`nלהסיר את WifiGate לחלוטין (משימות, כללי חומת אש, קבצים, קיצורים)?") 'WifiGate' 'YesNo' 'Question'
if ($ans -eq 'Yes') {
    Invoke-Uninstall
    [void](Show-Message 'WifiGate הוסר. Wi-Fi פתוח, ואין עוד חסימה.' 'WifiGate' 'OK' 'Information')
}
