# WifiGate - Install.ps1
# Flow: show planned changes -> consent -> set password + recovery code -> copy files ->
# SELF-TEST of lock/unlock/recovery (auto-reverting) -> only then register tasks and lock.

$ErrorActionPreference = 'Stop'
$WifiGuid = $null   # detected automatically in step 1 (works on any PC)

$srcDir = Join-Path $PSScriptRoot 'src'
. (Join-Path $srcDir 'Common.ps1')

if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
. (Join-Path $srcDir 'Ui.ps1')

function Stop-Install([string]$Text) { [void](Show-Message $Text 'WifiGate - התקנה' 'OK' 'Warning'); exit 1 }

# Creates a .lnk with the "Run as administrator" flag. WScript.Shell is ANSI-only (breaks on Hebrew paths),
# so the .lnk is built at an ASCII-only path and then written to its final place with .NET.
function New-GateShortcut([string]$Folder, [string]$Name, [string]$ScriptName, [string]$Icon, [string]$Hotkey = '', [bool]$Hidden = $true) {
    [void][IO.Directory]::CreateDirectory($Folder)
    $final = Join-Path $Folder ($Name + '.lnk')
    $tmp = Join-Path $script:ProgDir ('tmp-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($tmp)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $win = ''; if ($Hidden) { $win = '-WindowStyle Hidden ' }
    $s.Arguments = '-NoProfile -ExecutionPolicy Bypass ' + $win + '-File "' + (Join-Path $script:ProgDir $ScriptName) + '"'
    $s.WorkingDirectory = $script:ProgDir
    $s.IconLocation = $Icon
    if ($Hotkey) { $s.Hotkey = $Hotkey }
    $s.Save()
    $bytes = [IO.File]::ReadAllBytes($tmp)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($final, $bytes)
    [IO.File]::Delete($tmp)
}

try {
# ---- 0. existing installation? ----
if ((Test-Path $script:StateFile) -or (Test-Path $script:ProgDir)) {
    $complete = [bool](Get-ScheduledTask -TaskName 'WifiGate-Boot' -ErrorAction SilentlyContinue)
    if ($complete) {
        Stop-Install "WifiGate כבר מותקן.`n`nפתחו את הקובץ System Console בשולחן העבודה, לחצו 4 ובחרו הסרה, ואז הריצו את ההתקנה שוב."
    }
    Invoke-Uninstall    # leftovers of an incomplete/failed earlier install: clean them silently
}

# ---- 1. detect the Wi-Fi adapter automatically (by type, then remembered by GUID) ----
function Get-WifiCandidates {
    $list = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -notmatch 'Virtual|Direct|Bluetooth|Hyper-V|VPN|TAP|Loopback' -and
        ( $_.InterfaceType -eq 71 -or
          [string]$_.PhysicalMediaType -match '802\.11|Wireless' -or
          $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' )
    })
    return $list
}

$cands = @(Get-WifiCandidates)
if ($cands.Count -eq 0) {
    $all = (Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InterfaceDescription)  $($_.InterfaceGuid)" }) -join "`n"
    Stop-Install "לא נמצא מתאם Wi-Fi במחשב זה.`nלא בוצע שום שינוי.`n`nמתאמים שנמצאו:`n$all"
}

if ($cands.Count -eq 1) {
    $wifi = $cands[0]
} else {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'WifiGate - בחירת מתאם'; $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $f.ClientSize = New-Object System.Drawing.Size(480, 230)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'נמצאו כמה מתאמי Wi-Fi. בחרו את המתאם לחסימה:'; $l.SetBounds(15, 12, 450, 22)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.SetBounds(15, 40, 450, 130)
    foreach ($c in $cands) { [void]$lb.Items.Add("$($c.InterfaceDescription)  [$($c.Status)]") }
    $lb.SelectedIndex = 0
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'אישור'; $ok.DialogResult = 'OK'; $ok.SetBounds(15, 185, 150, 30)
    $cn = New-Object System.Windows.Forms.Button
    $cn.Text = 'ביטול'; $cn.DialogResult = 'Cancel'; $cn.SetBounds(180, 185, 150, 30)
    $f.Controls.AddRange(@($l, $lb, $ok, $cn)); $f.AcceptButton = $ok; $f.CancelButton = $cn
    $res = $f.ShowDialog(); $idx = $lb.SelectedIndex; $f.Dispose()
    if ([string]$res -ne 'OK' -or $idx -lt 0) { Stop-Install 'ההתקנה בוטלה. לא בוצע שום שינוי.' }
    $wifi = $cands[$idx]
}
$WifiGuid = [string]$wifi.InterfaceGuid

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
6. קובץ אחד בשולחן העבודה בשם 'System Console': חלון טרמינל עם תפריט באנגלית (1 פתיחה, 2 נעילה, 3 בדיקות, 4 שחזור). בנוסף שני קיצורי מקשים בתפריט התחל: Ctrl+Alt+P לפתיחה ו-Ctrl+Alt+X לנעילה.

לא ישונה: Ethernet ושאר מתאמי הרשת, וחשבון המשתמש שלכם.

לפני הפעלת החסימה תתבצע בדיקה עצמית אוטומטית של הנעילה, הפתיחה והשחזור (כמה שניות, ה-Wi-Fi יתנתק ויחזור).
ביטול בכל עת: ב-System Console לוחצים 4 (סיסמה או קוד שחזור).

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
if (-not (Show-CodeDialog $code)) { Stop-Install 'ההתקנה בוטלה. לא בוצע שום שינוי.' }

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

# One visible file on the Desktop (a terminal menu 1-4). The two hotkeys live in the Start menu.
New-GateShortcut ([Environment]::GetFolderPath('Desktop')) $script:DeskName 'Console.ps1' 'imageres.dll,11' '' $false
$hk = Join-Path ([Environment]::GetFolderPath('Programs')) $script:StartFolder
New-GateShortcut $hk 'Open'  'Unlock-UI.ps1' 'shell32.dll,44' 'CTRL+ALT+P'
New-GateShortcut $hk 'Close' 'Lock.ps1'      'shell32.dll,47' 'CTRL+ALT+X'

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
    $prob = Get-BlockRulesProblem $name
    if ($prob) { throw "כללי חומת האש לא נוצרו כראוי: $prob" }
    if ((Get-WifiAdapter).Status -ne 'Disabled') { throw 'המתאם לא כובה.' }
    if (Test-SecretRecord 'wrong-password-xyz' (Read-Json $script:AuthFile).Password) { throw 'אימות סיסמה שגוי התקבל.' }

    $r = Invoke-Unlock $pw                                              # exercise the real unlock path
    if (-not $r.Ok) { throw 'פתיחה בסיסמה נכשלה בבדיקה.' }
    if (@(Get-BlockRules).Count -ne 0) { throw 'הכללים לא הוסרו בפתיחה.' }
    if ((Get-WifiAdapter).Status -eq 'Disabled') { throw 'המתאם לא הופעל בפתיחה.' }

    Set-WifiBlock                                                       # lock again, then recover with the code
    $r = Invoke-Recovery $code
    if (-not $r.Ok) { throw 'שחזור בקוד נכשל בבדיקה.' }
    if (@(Get-BlockRules).Count -ne 0) { throw 'השחזור לא הסיר את הכללים.' }
    if ((Get-WifiAdapter).Status -eq 'Disabled') { throw 'השחזור לא הפעיל את המתאם.' }
} catch { $fail = $_.Exception.Message }
finally { Unregister-ScheduledTask -TaskName 'WifiGate-TrialFailsafe' -Confirm:$false -ErrorAction SilentlyContinue }

if ($fail) {
    try { Invoke-Uninstall } catch { }
    Stop-Install "הבדיקה העצמית נכשלה: $fail`n`nהכל הוחזר לקדמותו וה-Wi-Fi פתוח. החסימה לא הופעלה."
}

# ---- 6. final confirmation, then activate ----
$go = Show-Message "הבדיקה העצמית עברה: נעילה, פתיחה בסיסמה ושחזור בקוד עובדים.`n`nלהפעיל את החסימה עכשיו? ה-Wi-Fi ייחסם עד שתזינו סיסמה (System Console, ואז 1)." 'WifiGate' 'YesNo' 'Question'
if ($go -ne 'Yes') {
    Invoke-Uninstall
    [void](Show-Message 'החסימה לא הופעלה, והתוכנה הוסרה. אפשר להריץ את ההתקנה שוב בכל עת.' 'WifiGate' 'OK' 'Information')
    exit 0
}
Register-WifiGateTasks
Invoke-Lock
[void](Show-Message "החסימה פעילה.`n`nלפתיחה: הקובץ System Console בשולחן העבודה, ואז 1 (או Ctrl+Alt+P).`nמומלץ להריץ בדיקות (3) ולפעול לפי ה-README." 'WifiGate' 'OK' 'Information')
} catch {
    $msg = $_.Exception.Message + "`n`n" + $_.InvocationInfo.PositionMessage
    try { Invoke-Uninstall } catch { }
    try { $msg | Set-Content -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'WifiGate-error.txt') -Encoding UTF8 } catch { }
    Stop-Install "ההתקנה נכשלה בשגיאה:`n`n$msg`n`nהכל הוחזר לקדמותו וה-Wi-Fi פתוח. השגיאה נשמרה גם בקובץ WifiGate-error.txt בשולחן העבודה."
}
