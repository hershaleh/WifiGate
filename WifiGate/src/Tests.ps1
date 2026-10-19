# WifiGate - Tests.ps1 : verification menu (Hebrew). Results are shown in a window and logged.
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
. (Join-Path $PSScriptRoot 'Ui.ps1')

$script:Res = New-Object System.Collections.Generic.List[string]
$script:Fails = 0
function Add-Res([string]$Status, [string]$Text) {
    # Status: PASS / FAIL / SKIP / INFO
    if ($Status -eq 'FAIL') { $script:Fails++ }
    $script:Res.Add(("[{0}] {1}" -f $Status, $Text))
}
function Finish-Report([string]$Title) {
    $script:Res.Add('')
    if ($script:Fails -eq 0) { $script:Res.Add('סיכום: אין כשלים.') } else { $script:Res.Add("סיכום: $($script:Fails) כשלים.") }
    $text = ($script:Res -join "`r`n")
    Write-Log ("TESTS " + $Title + ": " + ($script:Res -join ' | '))
    Show-Report $Title $text
    $script:Res.Clear(); $script:Fails = 0
}
function Get-State { try { (Read-Json $script:StateFile) } catch { $null } }

# ---------- 1. general ----------
function Test-General {
    try { $a = Get-WifiAdapter; Add-Res 'PASS' "המתאם נמצא לפי GUID: $($a.InterfaceDescription), מצב: $($a.Status)" }
    catch { Add-Res 'FAIL' "המתאם לא נמצא: $($_.Exception.Message)"; return }
    $st = Get-State
    if (-not $st) { Add-Res 'FAIL' 'קובץ המצב חסר או פגום (ייחשב כנעול).' } else { Add-Res 'INFO' "מצב: $($st.Mode)" }
    if ($st -and $st.Mode -eq 'unlocked') {
        $n = @(Get-BlockRules).Count
        if ($n -eq 0) { Add-Res 'PASS' 'מצב פתוח: אין כללי חסימה (כמצופה).' } else { Add-Res 'FAIL' "מצב פתוח אבל נמצאו $n כללי חסימה." }
    } else {
        if (Test-BlockRulesValid $a.Name) { Add-Res 'PASS' 'שני כללי החסימה (נכנס ויוצא) קיימים, פעילים ומוגבלים למתאם ה-Wi-Fi בלבד.' }
        else { Add-Res 'FAIL' 'כללי החסימה חסרים או שגויים (המשימה תתקן בתוך דקה).' }
        if ($a.Status -eq 'Disabled') { Add-Res 'PASS' 'המתאם כבוי.' } else { Add-Res 'INFO' "המתאם במצב $($a.Status), החסימה נשענת על חומת האש." }
    }
    $fw = Get-NetFirewallProfile | Where-Object { $_.Enabled -ne 'True' }
    if (@($fw).Count -eq 0) { Add-Res 'PASS' 'חומת האש פעילה בכל הפרופילים.' } else { Add-Res 'FAIL' 'חומת האש כבויה בחלק מהפרופילים (חוסם לא יעבוד).' }
    foreach ($tn in 'WifiGate-Boot', 'WifiGate-Tick') {
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne 'Disabled') { Add-Res 'PASS' "המשימה $tn קיימת ופעילה." } else { Add-Res 'FAIL' "המשימה $tn חסרה או מושבתת." }
    }
    # Ethernet / other adapters untouched
    $wifiAlias = $a.Name
    $other = @(Get-BlockRules | Get-NetFirewallInterfaceFilter |
        ForEach-Object { @($_.InterfaceAlias) } | Where-Object { (Get-AdapterFilterIds $wifiAlias) -notcontains [string]$_ })
    if ($other.Count -eq 0) { Add-Res 'PASS' 'אף כלל של WifiGate אינו מתייחס למתאם אחר.' } else { Add-Res 'FAIL' 'כלל של WifiGate מתייחס למתאם נוסף.' }
    $snap = @(Read-Json $script:SnapshotFile)
    foreach ($s in $snap) {
        $cur = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $s.Guid } | Select-Object -First 1
        if (-not $cur) { Add-Res 'INFO' "המתאם $($s.Name) לא נמצא כעת."; continue }
        if ($s.Status -ne 'Disabled' -and $cur.Status -eq 'Disabled') { Add-Res 'FAIL' "המתאם $($cur.Name) כבוי, אך היה פעיל בהתקנה." }
        else { Add-Res 'PASS' "המתאם $($cur.Name) לא כובה על ידי WifiGate (מצב: $($cur.Status))." }
    }
    $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue)
    if ($hib -and $hib.PSObject.Properties['HiberbootEnabled'] -and $hib.HiberbootEnabled -eq 1) {
        Add-Res 'INFO' 'הפעלה מהירה (Fast Startup) דלוקה: "כיבוי" אינו אתחול מלא, ולכן הנעילה מתבצעת גם בהתחברות (logon).'
    }
}

# ---------- 2. after reboot ----------
function Test-AfterReboot {
    $st = Get-State
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Add-Res 'INFO' "זמן אתחול אחרון של Windows: $boot"
    if ($st -and $st.Mode -eq 'locked') { Add-Res 'PASS' 'המצב הוא נעול.' } else { Add-Res 'FAIL' 'המצב אינו נעול. האם פתחתם Wi-Fi ואחר כך אתחלתם?' }
    if ($st -and ([datetime]$st.ChangedAt) -gt $boot) { Add-Res 'PASS' 'הנעילה בוצעה אחרי האתחול (המשימה פעלה).' }
    else { Add-Res 'FAIL' 'לא נמצאה נעילה שבוצעה אחרי האתחול האחרון.' }
    $a = Get-WifiAdapter
    if (Test-BlockRulesValid $a.Name) { Add-Res 'PASS' 'כללי החסימה קיימים.' } else { Add-Res 'FAIL' 'כללי החסימה חסרים.' }
    if ($a.Status -eq 'Disabled') { Add-Res 'PASS' 'המתאם כבוי.' } else { Add-Res 'FAIL' "המתאם לא כבוי ($($a.Status))." }
    $i = Get-ScheduledTaskInfo -TaskName 'WifiGate-Boot' -ErrorAction SilentlyContinue
    if ($i) { Add-Res 'INFO' "ריצה אחרונה של WifiGate-Boot: $($i.LastRunTime), תוצאה: $($i.LastTaskResult)" }
}

# ---------- 3. one-action unlock ----------
function Test-UnlockFlow {
    $pw = Read-SecretDialog 'בדיקת פתיחה: הזינו את הסיסמה.'
    if ($null -eq $pw) { return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Unlock $pw
    $sw.Stop()
    if (-not $r.Ok) { Add-Res 'FAIL' "הפתיחה נכשלה: $($r.Message)"; return }
    Add-Res 'PASS' ("פעולה אחת (סיסמה בלבד) ביצעה אימות, הסרת כללים והפעלת מתאם תוך {0:N1} שניות." -f $sw.Elapsed.TotalSeconds)
    if (@(Get-BlockRules).Count -eq 0) { Add-Res 'PASS' 'כללי החסימה הוסרו.' } else { Add-Res 'FAIL' 'כללי החסימה עדיין קיימים.' }
    if (Wait-AdapterUp 25) { Add-Res 'PASS' 'המתאם פעיל ומחובר.' } else { Add-Res 'INFO' 'המתאם הופעל אך עדיין לא מחובר לרשת (ייתכן שאין רשת מוכרת בטווח).' }
    $st = Get-State
    if ($st -and $st.Mode -eq 'unlocked') { Add-Res 'PASS' 'המצב נשמר כפתוח.' } else { Add-Res 'FAIL' 'המצב לא נשמר.' }
    if ((Show-Message 'לנעול את ה-Wi-Fi מחדש עכשיו?' 'WifiGate' 'YesNo' 'Question') -eq 'Yes') {
        Invoke-Lock; Add-Res 'INFO' 'ה-Wi-Fi ננעל מחדש.'
    } else { Add-Res 'INFO' 'ה-Wi-Fi נשאר פתוח עד נעילה, אתחול או התחברות.' }
}

# ---------- 4. traffic test (re-enabling the adapter must not restore browsing) ----------
function Test-TcpOnce([string]$Ip, [int]$Port, [int]$Ms) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $iar = $c.BeginConnect($Ip, $Port, $null, $null); return ($iar.AsyncWaitHandle.WaitOne($Ms) -and $c.Connected) }
    catch { return $false } finally { $c.Close() }
}
function Test-Traffic {
    $st = Get-State
    if (-not $st -or $st.Mode -ne 'locked') { Add-Res 'SKIP' 'הבדיקה דורשת מצב נעול. נעלו קודם.'; return }
    $a = Get-WifiAdapter
    $idx = $a.ifIndex
    $others = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -ne $idx })
    if ($others.Count -gt 0) {
        Add-Res 'SKIP' 'יש חיבור אינטרנט נוסף (למשל Ethernet), ולכן אי אפשר להוכיח שהתעבורה עברה דרך ה-Wi-Fi. נתקו כבל Ethernet והריצו שוב.'
        return
    }
    try {
        Enable-NetAdapter -Name $a.Name -Confirm:$false     # simulate "re-enable via Windows settings"
        Add-Res 'INFO' 'המתאם הופעל ידנית כדי לדמות עקיפה דרך ההגדרות.'
        $ip = $null; $end = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $end -and -not $ip) {
            $ip = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
            if (-not $ip) { Start-Sleep -Seconds 1 }
        }
        if (-not $ip) { Add-Res 'SKIP' 'ה-Wi-Fi לא התחבר לרשת בטווח הזמן (אין רשת מוכרת?).'; return }
        $blocked = -not ((Test-TcpOnce '1.1.1.1' 443 6000) -or (Test-TcpOnce '8.8.8.8' 443 6000))
        # positive control: remove the rules for a few seconds and verify the Wi-Fi really has internet
        Get-BlockRules | Remove-NetFirewallRule
        Start-Sleep -Seconds 2
        $control = (Test-TcpOnce '1.1.1.1' 443 8000) -or (Test-TcpOnce '8.8.8.8' 443 8000)
        Set-WifiBlock
        if (-not $control) { Add-Res 'SKIP' 'גם בלי חסימה אין אינטרנט ב-Wi-Fi כעת, ולכן הבדיקה לא חד-משמעית.' }
        elseif ($blocked) { Add-Res 'PASS' 'עם מתאם פעיל ומחובר והחסימה פעילה: אין גלישה. בלי החסימה: יש גלישה. החסימה היא שמונעת אותה.' }
        else { Add-Res 'FAIL' 'הייתה גלישה דרך ה-Wi-Fi למרות החסימה!' }
    } finally {
        try { Set-WifiBlock } catch { Write-Log "traffic test restore error: $($_.Exception.Message)" }
        Add-Res 'INFO' 'החסימה שוחזרה.'
    }
}

# ---------- menu ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'WifiGate - בדיקות'; $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(380, 250); $form.TopMost = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$items = @(
    @('1. בדיקה כללית (חסימה, משימות, Ethernet)',                    { Test-General;     Finish-Report 'בדיקה כללית' }),
    @('2. בדיקה אחרי אתחול',                                         { Test-AfterReboot; Finish-Report 'בדיקה אחרי אתחול' }),
    @('3. בדיקת פתיחה בסיסמה (פעולה אחת)',                           { Test-UnlockFlow;  Finish-Report 'בדיקת פתיחה' }),
    @('4. בדיקת גלישה והפעלה מחדש של המתאם (נתקו Ethernet)',       { Test-Traffic;     Finish-Report 'בדיקת גלישה' })
)
$y = 15
foreach ($it in $items) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $it[0]; $b.SetBounds(20, $y, 340, 45)
    $act = $it[1]
    $b.Add_Click({ param($s, $e) $s.Enabled = $false; try { & $s.Tag } catch { Add-Res 'FAIL' "שגיאה: $($_.Exception.Message)"; Finish-Report 'שגיאה' } finally { $s.Enabled = $true } })
    $b.Tag = $act
    $form.Controls.Add($b)
    $y += 55
}
[void]$form.ShowDialog()
