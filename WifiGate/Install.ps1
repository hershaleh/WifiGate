# WifiGate - Install.ps1
# Flow: show planned changes -> consent -> set password + recovery code -> copy files ->
# SELF-TEST of lock/unlock/recovery (auto-reverting) -> only then register tasks and lock.

$ErrorActionPreference = 'Stop'
$WifiGuid = '{E370A64A-8594-4758-ACE3-0DF2C7B75A28}'   # Intel(R) Wi-Fi 6 AX201 160MHz

$srcDir = Join-Path $PSScriptRoot 'src'
. (Join-Path $srcDir 'Common.ps1')

if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
. (Join-Path $srcDir 'Ui.ps1')

function Stop-Install([string]$Text) { [void](Show-Message $Text 'WifiGate - התקנה' 'OK' 'Warning'); exit 1 }

function New-GateShortcut([string]$Name, [string]$ScriptName, [string]$Icon) {
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desk ($Name + '.lnk')
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $script:ProgDir $ScriptName) + '"'
    $s.WorkingDirectory = $script:ProgDir
    $s.IconLocation = $Icon
    $s.Save()
    $b = [IO.File]::ReadAllBytes($lnk)          # "Run as administrator" flag
    $b[0x15] = $b[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($lnk, $b)
}

# ---- 0. existing installation? ----
if ((Test-Path $script:StateFile) -or (Test-Path $script:ProgDir)) {
    Stop-Install "WifiGate כבר מותקן (או שהתקנה קודמת לא הושלמה).`n`nהשתמשו בקיצור 'WifiGate - שחזור' בשולחן העבודה, ובחרו הסרה, ואז הריצו את ההתקנה שוב."
}

# ---- 1. find the adapter by GUID ----
$wifi = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $WifiGuid } | Select-Object -First 1
if (-not $wifi) {
    $all = (Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InterfaceDescription)  $($_.InterfaceGuid)" }) -join "`n"
    Stop-Install "לא נמצא מתאם עם המזהה $WifiGuid.`nלא בוצע שום שינוי.`n`nמתאמים שנמצאו:`n$all"
}

# ---- 2. planned changes + consent ----
$plan = @"
זיהיתי את המתאם: $($wifi.InterfaceDescription)
מצב נוכחי: $($wifi.Status)

ההתקנה תבצע את השינויים הבאים (דורשת הרשאות מנהל):

1. תיקיית תוכנה: C:\Program Files\WifiGate
2. תיקיית נתונים: C:\ProgramData\WifiGate (סיסמה מוצפנת, מצב, יומן) - גישה למנהלים ולמערכת בלבד.
3. שני כללי חומת אש (Windows Firewall) החוסמים תעבורה נכנסת ויוצאת במתאם ה-Wi-Fi בלבד. אם חומת האש כבויה - היא תופעל.
4. כיבוי מתאם ה-Wi-Fi בזמן חסימה.
5. שתי משימות מתוזמנות (חשבון SYSTEM): נעילה באתחול ובהתחברות, ותיקון החסימה כל דקה.
6. שלושה קיצורי דרך בשולחן העבודה: פתיחה, שחזור, בדיקות.

לא ישונה: Ethernet ושאר מתאמי הרשת, וחשבון המשתמש שלכם.

לפני הפעלת החסימה תתבצע בדיקה עצמית אוטומטית של הנעילה, הפתיחה והשחזור (כמה שניות, ה-Wi-Fi יתנתק ויחזור).
ביטול בכל עת: קיצור 'שחזור' (סיסמה או קוד שחזור).

להמשיך?
"@
if ((Show-Message $plan 'WifiGate - התקנה' 'YesNo' 'Question') -ne 'Yes') { exit 0 }

# ---- 3. password + recovery code ----
$pw = $null
while ($true) {
    $p1 = Read-SecretDialog 'בחרו סיסמה לפתיחת ה-Wi-Fi (לפחות 8 תווים):'
    if ($null -eq $p1) { exit 0 }
    if ($p1.Length -lt 8) { [void](Show-Message 'הסיסמה קצרה מדי (מינימום 8 תווים).' 'WifiGate' 'OK' 'Warning'); continue }
    $p2 = Read-SecretDialog 'הקלידו את הסיסמה שוב לאימות:'
    if ($null -eq $p2) { exit 0 }
    if ($p1 -ne $p2) { [void](Show-Message 'הסיסמאות אינן זהות. נסו שוב.' 'WifiGate' 'OK' 'Warning'); continue }
    $pw = $p1; break
}
$code = New-RecoveryCode
$ack = Show-Message ("קוד השחזור שלכם:`n`n$code`n`nרשמו אותו על נייר ושמרו אותו במקום בטוח. הוא מאפשר לפתוח את ה-Wi-Fi אם שכחתם את הסיסמה או אם החלון נכשל. הוא לא יוצג שוב.`n`nרשמתם?") 'WifiGate - קוד שחזור' 'YesNo' 'Warning'
if ($ack -ne 'Yes') { Stop-Install 'ההתקנה בוטלה. לא בוצע שום שינוי.' }

# ---- 4. files ----
New-Item -ItemType Directory -Path $script:ProgDir -Force | Out-Null
Copy-Item -Path (Join-Path $srcDir '*') -Destination $script:ProgDir -Recurse -Force
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
& icacls.exe $script:DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { Invoke-Uninstall; Stop-Install 'לא הצלחתי להגדיר הרשאות לתיקיית הנתונים. ההתקנה בוטלה והכל הוסר.' }

Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = $WifiGuid })
Write-Json $script:AuthFile ([pscustomobject]@{
    Version = 1
    Password = (New-SecretRecord $pw)
    Recovery = (New-SecretRecord (ConvertTo-NormalCode $code))
})
Set-State 'unlocked'
Write-Json $script:SnapshotFile (@(Get-NetAdapter | Where-Object { $_.InterfaceGuid -ne $WifiGuid } |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Guid = $_.InterfaceGuid; Status = [string]$_.Status } }))

New-GateShortcut 'WifiGate - פתיחת Wi-Fi' 'Unlock-UI.ps1' 'shell32.dll,44'
New-GateShortcut 'WifiGate - שחזור'       'Recovery.ps1'  'shell32.dll,238'
New-GateShortcut 'WifiGate - בדיקות'      'Tests.ps1'     'shell32.dll,23'

# ---- 5. self-test with automatic failsafe ----
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$failCmd = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `". '$($script:ProgDir)\Common.ps1'; Clear-WifiBlock`""
Register-ScheduledTask -TaskName 'WifiGate-TrialFailsafe' -Force `
    -Action (New-ScheduledTaskAction -Execute $ps -Argument $failCmd) `
    -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)) `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) | Out-Null

$fail = $null
try {
    $name = (Get-WifiAdapter).Name
    Set-WifiBlock                                                       # trial lock (state stays 'unlocked')
    if (-not (Test-BlockRulesValid $name)) { throw 'כללי חומת האש לא נוצרו כראוי.' }
    if ((Get-WifiAdapter).Status -ne 'Disabled') { throw 'המתאם לא כובה.' }
    if (Test-SecretRecord 'wrong-password-xyz' (Read-Json $script:AuthFile).Password) { throw 'אימות סיסמה שגוי התקבל.' }

    $r = Invoke-Unlock $pw                                              # exercise the real unlock path
    if (-not $r.Ok) { throw 'פתיחה בסיסמה נכשלה בבדיקה.' }
    if (@(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue).Count -ne 0) { throw 'הכללים לא הוסרו בפתיחה.' }
    if ((Get-WifiAdapter).Status -eq 'Disabled') { throw 'המתאם לא הופעל בפתיחה.' }

    Set-WifiBlock                                                       # lock again, then recover with the code
    $r = Invoke-Recovery $code
    if (-not $r.Ok) { throw 'שחזור בקוד נכשל בבדיקה.' }
    if (@(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue).Count -ne 0) { throw 'השחזור לא הסיר את הכללים.' }
    if ((Get-WifiAdapter).Status -eq 'Disabled') { throw 'השחזור לא הפעיל את המתאם.' }
} catch { $fail = $_.Exception.Message }
finally { Unregister-ScheduledTask -TaskName 'WifiGate-TrialFailsafe' -Confirm:$false -ErrorAction SilentlyContinue }

if ($fail) {
    try { Invoke-Uninstall } catch { }
    Stop-Install "הבדיקה העצמית נכשלה: $fail`n`nהכל הוחזר לקדמותו וה-Wi-Fi פתוח. החסימה לא הופעלה."
}

# ---- 6. final confirmation, then activate ----
$go = Show-Message "הבדיקה העצמית עברה: נעילה, פתיחה בסיסמה ושחזור בקוד עובדים.`n`nלהפעיל את החסימה עכשיו? ה-Wi-Fi ייחסם עד שתזינו סיסמה בקיצור 'WifiGate - פתיחת Wi-Fi'." 'WifiGate' 'YesNo' 'Question'
if ($go -ne 'Yes') {
    Invoke-Uninstall
    [void](Show-Message 'החסימה לא הופעלה, והתוכנה הוסרה. אפשר להריץ את ההתקנה שוב בכל עת.' 'WifiGate' 'OK' 'Information')
    exit 0
}
Register-WifiGateTasks
Invoke-Lock
[void](Show-Message "החסימה פעילה.`n`nלפתיחה: קיצור 'WifiGate - פתיחת Wi-Fi' בשולחן העבודה.`nמומלץ להריץ את 'WifiGate - בדיקות' ולפעול לפי ה-README." 'WifiGate' 'OK' 'Information')
