# WifiGate - Install.ps1
# Flow: visual wizard (adapter, what to block, visible/hidden access, names + icon, password, summary) -> recovery code -> copy files ->
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
. (Join-Path $srcDir 'Wizard.ps1')

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


$pfm = $null
try {
# ---- 0. existing installation? ----
if ((Test-Path $script:StateFile) -or (Test-Path $script:ProgDir)) {
    $complete = [bool](Get-ScheduledTask -TaskName 'WifiGate-Boot' -ErrorAction SilentlyContinue)
    if ($complete) {
        Stop-Install "WifiGate כבר מותקן.`n`nפתחו את 'שחזור' (בתפריט התחל, או במסוף השחור על ידי לחיצה על 4), הזינו סיסמה או קוד שחזור ובחרו הסרה. אחר כך הריצו את ההתקנה שוב."
    }
    Invoke-Uninstall    # leftovers of an incomplete/failed earlier install: clean them silently
}

# ---- 1. detect Wi-Fi adapters ----
function Get-WifiCandidates {
    $list = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -notmatch 'Virtual|Direct|Bluetooth|Hyper-V|VPN|TAP|Loopback' -and
        ( $_.InterfaceType -eq 71 -or
          [string]$_.PhysicalMediaType -match '802\.11|Wireless' -or
          $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' )
    })
    return $list
}

$allNics = @(Get-NetAdapter -ErrorAction SilentlyContinue)
$cands = @(Get-WifiCandidates)
if ($cands.Count -eq 0) {
    $all = ($allNics | ForEach-Object { "$($_.InterfaceDescription)  $($_.InterfaceGuid)" }) -join "`n"
    Stop-Install "לא נמצא מתאם Wi-Fi במחשב זה.`nלא בוצע שום שינוי.`n`nמתאמים שנמצאו:`n$all"
}

# ---- 2. the visual wizard (choices, password, summary) ----
$wf = New-InstallWizard $cands $allNics
$wres = $wf.ShowDialog()
if ([string]$wres -ne 'OK') { $wf.Dispose(); exit 0 }
$ch = Get-WizardResult
$wf.Dispose()
$wifi = $ch.Adapter
$WifiGuid = [string]$wifi.InterfaceGuid
$pw = [string]$ch.Password

# ---- 3. recovery code ----
$code = New-RecoveryCode
if (-not (Show-CodeDialog $code)) { Stop-Install 'ההתקנה בוטלה. לא בוצע שום שינוי.' }

$pfm = New-ProgressForm
$pfm.Show(); [System.Windows.Forms.Application]::DoEvents()

# ---- 4. files ----
Set-Progress 'מעתיק קבצים...' 0.1
New-Item -ItemType Directory -Path $script:ProgDir -Force | Out-Null
Copy-Item -Path (Join-Path $srcDir '*') -Destination $script:ProgDir -Recurse -Force
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
& icacls.exe $script:DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { Invoke-Uninstall; Stop-Install 'לא הצלחתי להגדיר הרשאות לתיקיית הנתונים. ההתקנה בוטלה והכל הוסר.' }

Set-Progress 'שומר הגדרות וסיסמה...' 0.25
Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = $WifiGuid; BlockCategories = @($ch.Categories); AccessMode = $(if ($ch.Hidden) { 'hidden' } else { 'visible' }) })
Write-Json $script:AuthFile ([pscustomobject]@{
    Version = 1
    Password = (New-SecretRecord $pw)
    Recovery = (New-SecretRecord (ConvertTo-NormalCode $code))
})
Set-State 'unlocked'
Write-Json $script:SnapshotFile (@(Get-NetAdapter | Where-Object { $_.InterfaceGuid -ne $WifiGuid } |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Guid = $_.InterfaceGuid; Status = [string]$_.Status } }))

# ---- 5. shortcuts (recorded in config.json so the uninstaller removes exactly these) ----
Set-Progress 'יוצר קיצורים...' 0.4
$desk = [Environment]::GetFolderPath('Desktop')
$progs = [Environment]::GetFolderPath('Programs')
$made = @(); $folders = @()
$openHk = ''; $lockHk = ''
if ($ch.Hotkeys) { $openHk = 'CTRL+ALT+P'; $lockHk = 'CTRL+ALT+X' }
if ($ch.Hidden) {
    $icon = 'imageres.dll,11'
    if ($ch.IconPath) { $icon = $ch.IconPath + ',0' }
    New-GateShortcut $desk $ch.Name 'Console.ps1' $icon '' $false
    $made += (Join-Path $desk ($ch.Name + '.lnk'))
    if ($ch.Hotkeys) {
        $hk = Join-Path $progs $ch.Name
        New-GateShortcut $hk 'Open'  'Unlock-UI.ps1' $icon $openHk
        New-GateShortcut $hk 'Close' 'Lock.ps1'      $icon $lockHk
        $folders += $hk
    }
} else {
    New-GateShortcut $desk $ch.OpenName 'Unlock-UI.ps1' 'shell32.dll,44' $openHk
    New-GateShortcut $desk $ch.LockName 'Lock.ps1'      'shell32.dll,47' $lockHk
    $made += (Join-Path $desk ($ch.OpenName + '.lnk')); $made += (Join-Path $desk ($ch.LockName + '.lnk'))
    $hk = Join-Path $progs 'WifiGate'
    New-GateShortcut $hk 'בדיקות' 'Tests.ps1' 'shell32.dll,23'
    New-GateShortcut $hk 'שחזור והסרה' 'Recovery.ps1' 'shell32.dll,21'
    $folders += $hk
}
Set-ConfigValue 'Shortcuts' @($made)
Set-ConfigValue 'Folders' @($folders)

# ---- 6. self-test with automatic failsafe ----
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$failCmd = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `". '$($script:ProgDir)\Common.ps1'; Clear-WifiBlock`""
Register-ScheduledTask -TaskName 'WifiGate-TrialFailsafe' -Force `
    -Action (New-ScheduledTaskAction -Execute $ps -Argument $failCmd) `
    -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)) `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) | Out-Null

$fail = $null
try {
    Set-Progress 'בדיקה עצמית: נעילה...' 0.55
    $name = (Get-WifiAdapter).Name
    Set-WifiBlock                                                       # trial lock (state stays 'unlocked')
    $prob = Get-BlockRulesProblem $name
    if ($prob) { throw "כללי חומת האש לא נוצרו כראוי: $prob" }
    if ((Get-WifiAdapter).Status -ne 'Disabled') { throw 'המתאם לא כובה.' }
    if (Test-SecretRecord 'wrong-password-xyz' (Read-Json $script:AuthFile).Password) { throw 'אימות סיסמה שגוי התקבל.' }

    Set-Progress 'בדיקה עצמית: פתיחה בסיסמה...' 0.7
    $r = Invoke-Unlock $pw                                              # exercise the real unlock path
    if (-not $r.Ok) { throw 'פתיחה בסיסמה נכשלה בבדיקה.' }
    if (@(Get-BlockRules).Count -ne 0) { throw 'הכללים לא הוסרו בפתיחה.' }
    if ((Get-WifiAdapter).Status -eq 'Disabled') { throw 'המתאם לא הופעל בפתיחה.' }

    Set-Progress 'בדיקה עצמית: שחזור בקוד...' 0.85
    Set-WifiBlock                                                       # lock again, then recover with the code
    $r = Invoke-Recovery $code
    if (-not $r.Ok) { throw 'שחזור בקוד נכשל בבדיקה.' }
    if (@(Get-BlockRules).Count -ne 0) { throw 'השחזור לא הסיר את הכללים.' }
    if ((Get-WifiAdapter).Status -eq 'Disabled') { throw 'השחזור לא הפעיל את המתאם.' }
} catch { $fail = $_.Exception.Message }
finally { Unregister-ScheduledTask -TaskName 'WifiGate-TrialFailsafe' -Confirm:$false -ErrorAction SilentlyContinue }

if ($fail) {
    try { $pfm.Close() } catch { }
    try { Invoke-Uninstall } catch { }
    Stop-Install "הבדיקה העצמית נכשלה: $fail`n`nהכל הוחזר לקדמותו וה-Wi-Fi פתוח. החסימה לא הופעלה."
}
Set-Progress 'מסיים...' 1.0
try { $pfm.Close() } catch { }

# ---- 7. final confirmation, then activate ----
if ($ch.Hidden) { $how = "לפתיחה: הקובץ '$($ch.Name)' בשולחן העבודה, ואז 1" } else { $how = "לפתיחה: הקובץ '$($ch.OpenName)' בשולחן העבודה" }
$go = Show-Message "הבדיקה העצמית עברה: נעילה, פתיחה בסיסמה ושחזור בקוד עובדים.`n`nלהפעיל את החסימה עכשיו? ה-Wi-Fi ייחסם עד שתזינו סיסמה ($how)." 'WifiGate' 'YesNo' 'Question'
if ($go -ne 'Yes') {
    Invoke-Uninstall
    [void](Show-Message 'החסימה לא הופעלה, והתוכנה הוסרה. אפשר להריץ את ההתקנה שוב בכל עת.' 'WifiGate' 'OK' 'Information')
    exit 0
}
Register-WifiGateTasks
Invoke-Lock
try { Start-ScheduledTask -TaskName 'WifiGate-Tray' -ErrorAction Stop } catch { Write-Log "tray start: $($_.Exception.Message)" }
[void](Show-Message "החסימה פעילה.`n`n$how.`nמומלץ להריץ בדיקות ולפעול לפי ה-README." 'WifiGate' 'OK' 'Information')
} catch {
    $msg = $_.Exception.Message + "`n`n" + $_.InvocationInfo.PositionMessage
    try { if ($pfm) { $pfm.Close() } } catch { }
    try { Invoke-Uninstall } catch { }
    try { $msg | Set-Content -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'WifiGate-error.txt') -Encoding UTF8 } catch { }
    Stop-Install "ההתקנה נכשלה בשגיאה:`n`n$msg`n`nהכל הוחזר לקדמותו וה-Wi-Fi פתוח. השגיאה נשמרה גם בקובץ WifiGate-error.txt בשולחן העבודה."
}
