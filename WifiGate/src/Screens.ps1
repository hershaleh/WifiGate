# WifiGate - Screens.ps1 : main window, change-password and daily-lock dialogs.
# Requires Common.ps1 and Ui.ps1 to be loaded first. Event handlers use $script:ui / $script:cp / $script:dl.

$script:AutoOptions = @(
    @{ Text = 'ללא'; Min = 0 }, @{ Text = '15 ד׳'; Min = 15 }, @{ Text = '30 ד׳'; Min = 30 },
    @{ Text = 'שעה'; Min = 60 }, @{ Text = '2 ש׳'; Min = 120 }, @{ Text = '4 ש׳'; Min = 240 }, @{ Text = '8 ש׳'; Min = 480 }
)

function Format-Remaining([timespan]$Left) {
    if ($Left.TotalSeconds -lt 60) { return 'פחות מדקה' }
    $h = [int][math]::Floor($Left.TotalHours); $m = $Left.Minutes
    if ($h -gt 0) { return "$h שעות ו-$m דקות" }
    return "$m דקות"
}

function Format-ShortDuration([int]$Minutes) {
    if ($Minutes -lt 60) { return "$Minutes ד׳" }
    if ($Minutes % 60 -eq 0) { return ("{0} ש׳" -f ($Minutes / 60)) }
    return ('{0}:{1:00} ש׳' -f [math]::Floor($Minutes / 60), ($Minutes % 60))
}

function Set-MainMessage([string]$Text, [string]$Kind = 'muted') {
    $ui = $script:ui
    $ui.Msg.Text = $Text
    switch ($Kind) { 'bad' { $ui.Msg.ForeColor = $script:Theme.Danger } 'ok' { $ui.Msg.ForeColor = $script:Theme.Ok } default { $ui.Msg.ForeColor = $script:Theme.Muted } }
}

function Set-IfChanged($Control, [string]$Text) { if ($Control.Text -ne $Text) { $Control.Text = $Text } }

function Update-MainView {
    $ui = $script:ui
    $st = Get-StateInfo
    $changed = ($ui.Locked -ne $st.Locked)
    $ui.Locked = $st.Locked
    if ($st.Locked) {
        Set-IfChanged $ui.Status 'Wi-Fi חסום'
        $ui.Status.ForeColor = $script:Theme.Danger
        Set-IfChanged $ui.Sub 'הזינו את הסיסמה כדי לפתוח את הגלישה'
    } else {
        Set-IfChanged $ui.Status 'Wi-Fi פתוח'
        $ui.Status.ForeColor = $script:Theme.Ok
        if ($st.AutoLockAt) {
            $left = $st.AutoLockAt - (Get-Date)
            if ($left.TotalSeconds -lt 0) { $left = [timespan]::Zero }
            Set-IfChanged $ui.Sub ("ייחסם אוטומטית בשעה " + $st.AutoLockAt.ToString('HH:mm') + " - בעוד " + (Format-Remaining $left))
        } else {
            Set-IfChanged $ui.Sub 'ללא נעילה אוטומטית. אפשר לקבוע טיימר למטה.'
        }
    }
    $hasTimer = [bool]$st.AutoLockAt
    $ui.LockedGroup | ForEach-Object { $_.Visible = $st.Locked }
    $ui.OpenGroup   | ForEach-Object { $_.Visible = (-not $st.Locked) }
    $ui.BtnCancelTimer.Visible = ((-not $st.Locked) -and $hasTimer)
    if ($hasTimer -ne $ui.HadTimer) {
        $ui.HadTimer = $hasTimer
        if ($hasTimer) { $ui.BtnSetTimer.SetBounds(30, 366, 163, 40); $ui.BtnCancelTimer.SetBounds(207, 366, 163, 40) }
        else           { $ui.BtnSetTimer.SetBounds(30, 366, 340, 40) }
        Set-Rounded $ui.BtnSetTimer 10; Set-Rounded $ui.BtnCancelTimer 10
    }
    if ($changed) { $ui.Icon.Invalidate() }
}

function Request-Password([string]$Prompt) {
    $pw = Read-SecretDialog $Prompt
    if ($null -eq $pw) { return $false }
    $r = Test-AuthSecret $pw $true
    if (-not $r.Ok) { Set-MainMessage $r.Message 'bad'; return $false }
    return $true
}

function Invoke-MainUnlock {
    $ui = $script:ui
    $pw = $ui.Input.Box.Text
    if (-not $pw) { Set-MainMessage 'הקלידו את הסיסמה.' 'bad'; return }
    $ui.Busy = $true; $ui.BtnUnlock.Enabled = $false
    Set-MainMessage 'בודק...' 'muted'; $ui.Form.Refresh()
    $ui.Input.Box.Clear()
    try {
        $mins = [int]$ui.LockedOptions[$ui.ChipsLocked.Tag.Index].Min
        $r = Invoke-Unlock $pw $mins
        if ($r.Ok) {
            try { Set-ConfigValue 'LastAutoMinutes' $mins } catch { }
            Set-MainMessage 'פותח את המתאם...' 'muted'; $ui.Form.Refresh()
            $up = Wait-AdapterUp 20 { [System.Windows.Forms.Application]::DoEvents() }
            if ($up) { Set-MainMessage 'Wi-Fi נפתח ומחובר.' 'ok' } else { Set-MainMessage 'Wi-Fi נפתח. ההתחברות לרשת עשויה לקחת כמה שניות.' 'ok' }
        } else { Set-MainMessage $r.Message 'bad' }
    } catch {
        Write-Log "UI unlock error: $($_.Exception.Message)"
        Set-MainMessage 'אירעה שגיאה. ראו README (שחזור).' 'bad'
    }
    $ui.Busy = $false; $ui.BtnUnlock.Enabled = $true
    Update-MainView
    if ($ui.Locked) { $ui.Input.Box.Focus() }
}

function Invoke-MainLock {
    $ui = $script:ui
    try { Invoke-Lock; Set-MainMessage 'Wi-Fi נחסם.' 'muted' } catch { Set-MainMessage 'שגיאה בחסימה.' 'bad'; Write-Log "UI lock error: $($_.Exception.Message)" }
    Update-MainView
    $ui.Input.Box.Focus()
}

function Invoke-MainSetTimer {
    $ui = $script:ui
    $mins = [int]$script:AutoOptions[$ui.ChipsOpen.Tag.Index + 1].Min
    $st = Get-StateInfo
    if ($st.Locked) { Update-MainView; return }
    $newAt = (Get-Date).AddMinutes($mins)
    # Extending an existing timer weakens the lock, so it needs the password.
    if ($st.AutoLockAt -and $newAt -gt $st.AutoLockAt) {
        if (-not (Request-Password 'הארכת זמן הנעילה דורשת סיסמה:')) { return }
    }
    try { Set-AutoLock $mins; Set-MainMessage 'הטיימר נקבע.' 'ok' } catch { Set-MainMessage 'שגיאה בקביעת הטיימר.' 'bad'; Write-Log "timer error: $($_.Exception.Message)" }
    Update-MainView
}

function Invoke-MainCancelTimer {
    if (-not (Request-Password 'ביטול הנעילה האוטומטית דורש סיסמה:')) { return }
    try { Set-AutoLock 0; Set-MainMessage 'הנעילה האוטומטית בוטלה.' 'muted' } catch { Set-MainMessage 'שגיאה.' 'bad' }
    Update-MainView
}

function Paint-MainIcon($Sender, $E) {
    $g = $E.Graphics; $g.SmoothingMode = 'AntiAlias'
    $w = $Sender.Width; $h = $Sender.Height
    $locked = $true
    if ($script:ui -and $script:ui.ContainsKey('Locked')) { $locked = $script:ui.Locked }
    if ($locked) { $col = $script:Theme.Danger } else { $col = $script:Theme.Ok }
    $bg = New-Object System.Drawing.SolidBrush($script:Theme.Card)
    $g.FillEllipse($bg, 2, 2, ($w - 5), ($h - 5)); $bg.Dispose()
    $ring = New-Object System.Drawing.Pen($col, [single]2.5)
    $g.DrawEllipse($ring, 2, 2, ($w - 5), ($h - 5)); $ring.Dispose()
    $cx = $w / 2; $by = $h * 0.66
    $pen = New-Object System.Drawing.Pen($col, [single]($w * 0.07))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    foreach ($k in 1, 2, 3) {
        $r = $w * 0.15 * $k + $w * 0.02
        $g.DrawArc($pen, [single]($cx - $r), [single]($by - $r), [single](2 * $r), [single](2 * $r), [single]225, [single]90)
    }
    $dot = New-Object System.Drawing.SolidBrush($col)
    $d = $w * 0.085
    $g.FillEllipse($dot, [single]($cx - $d), [single]($by - $d), [single](2 * $d), [single](2 * $d))
    $dot.Dispose(); $pen.Dispose()
    if ($locked) {
        $cut = New-Object System.Drawing.Pen($script:Theme.Card, [single]($w * 0.13))
        $sl = New-Object System.Drawing.Pen($col, [single]($w * 0.065))
        $cut.StartCap = 'Round'; $cut.EndCap = 'Round'; $sl.StartCap = 'Round'; $sl.EndCap = 'Round'
        $g.DrawLine($cut, [single]($w * 0.27), [single]($h * 0.22), [single]($w * 0.73), [single]($h * 0.80))
        $g.DrawLine($sl,  [single]($w * 0.27), [single]($h * 0.22), [single]($w * 0.73), [single]($h * 0.80))
        $cut.Dispose(); $sl.Dispose()
    }
}

function New-MainForm {
    $ui = @{ Locked = $true; Busy = $false; HadTimer = $false }
    $script:ui = $ui
    $f = New-ThemedForm 'WifiGate' 400 486
    $ui.Form = $f

    $ui.Icon = New-Object System.Windows.Forms.Panel
    $ui.Icon.SetBounds(144, 22, 112, 112); $ui.Icon.BackColor = $script:Theme.Bg
    Set-DoubleBuffered $ui.Icon
    $ui.Icon.Add_Paint({ param($s, $e) Paint-MainIcon $s $e })
    $ui.Status = New-ThemedLabel '' 20 142 360 36 18 $script:Theme.Text $true
    $ui.Sub    = New-ThemedLabel '' 20 180 360 40 10 $script:Theme.Muted

    # --- locked view ---
    $ui.Input = New-ThemedInput 30 232 340 $true
    $lblDur = New-ThemedLabel 'אחרי הפתיחה, נעל שוב אוטומטית:' 30 290 340 20 9.5 $script:Theme.Muted
    # first chip: the "after every unlock" default if configured, otherwise "none"
    $defMin = Get-DefaultAutoMinutes
    $first = @{ Text = 'ללא'; Min = 0 }
    if ($defMin -gt 0) { $first = @{ Text = (Format-ShortDuration $defMin); Min = $defMin } }
    $ui.LockedOptions = @($first) + @($script:AutoOptions | Select-Object -Skip 1)
    $ui.ChipsLocked = New-ChipRow 30 314 340 34 @($ui.LockedOptions | ForEach-Object { $_.Text })
    $ui.BtnUnlock = New-ThemedButton 'פתח Wi-Fi' 30 362 340 50 'primary'
    $ui.LockedGroup = @($ui.Input.Panel, $lblDur, $ui.ChipsLocked, $ui.BtnUnlock)

    # --- open view ---
    $ui.BtnLock = New-ThemedButton 'נעל עכשיו' 30 232 340 50 'danger'
    $lblTimer = New-ThemedLabel 'נעילה אוטומטית בעוד:' 30 294 340 20 9.5 $script:Theme.Muted
    $ui.ChipsOpen = New-ChipRow 30 318 340 34 @($script:AutoOptions | Select-Object -Skip 1 | ForEach-Object { $_.Text })
    $ui.BtnSetTimer = New-ThemedButton 'קבע טיימר' 30 366 340 40 'ghost'
    $ui.BtnCancelTimer = New-ThemedButton 'בטל טיימר' 207 366 163 40 'ghost'
    $ui.OpenGroup = @($ui.BtnLock, $lblTimer, $ui.ChipsOpen, $ui.BtnSetTimer)

    $ui.Msg = New-ThemedLabel '' 20 418 360 24 9.5 $script:Theme.Muted
    $ui.LinkPw = New-LinkLabel 'שינוי סיסמה' 40 450 150 24
    $ui.LinkDaily = New-LinkLabel 'נעילה אוטומטית' 210 450 150 24

    foreach ($c in @($ui.Icon, $ui.Status, $ui.Sub) + $ui.LockedGroup + $ui.OpenGroup + @($ui.BtnCancelTimer, $ui.Msg, $ui.LinkPw, $ui.LinkDaily)) { $f.Controls.Add($c) }
    $f.AcceptButton = $ui.BtnUnlock

    # remember the last chosen duration
    try {
        $cfg = Read-Json $script:ConfigFile
        $last = [int](Get-Prop $cfg 'LastAutoMinutes' 0)
        if ($defMin -le 0) {
            for ($i = 0; $i -lt $ui.LockedOptions.Count; $i++) { if ($ui.LockedOptions[$i].Min -eq $last) { Select-Chip $ui.ChipsLocked $i } }
        }
    } catch { }

    $ui.BtnUnlock.Add_Click({ Invoke-MainUnlock })
    $ui.BtnLock.Add_Click({ Invoke-MainLock })
    $ui.BtnSetTimer.Add_Click({ Invoke-MainSetTimer })
    $ui.BtnCancelTimer.Add_Click({ Invoke-MainCancelTimer })
    $ui.LinkPw.Add_Click({ if (Show-ChangePasswordDialog) { Set-MainMessage 'הסיסמה שונתה.' 'ok' } })
    $ui.LinkDaily.Add_Click({ if (Show-AutoLockDialog) { Set-MainMessage 'ההגדרות נשמרו.' 'ok' } })

    $ui.Timer = New-Object System.Windows.Forms.Timer
    $ui.Timer.Interval = 1000
    $ui.Timer.Add_Tick({ if (-not $script:ui.Busy) { Update-MainView } })
    $f.Add_Shown({ Update-MainView; $script:ui.Timer.Start(); if ($script:ui.Locked) { $script:ui.Input.Box.Focus() } })
    $f.Add_FormClosed({ $script:ui.Timer.Stop() })
    Update-MainView
    return $f
}

# ---------- change password ----------

function New-ChangePasswordForm {
    $cp = @{}
    $script:cp = $cp
    $f = New-ThemedForm 'WifiGate - שינוי סיסמה' 380 404
    $cp.Form = $f
    $f.Controls.Add((New-ThemedLabel 'שינוי סיסמה' 20 14 340 34 16 $script:Theme.Text $true))
    $cur = Add-Field $f 'הסיסמה הנוכחית (או קוד השחזור)' 58 $true
    $new = Add-Field $f 'סיסמה חדשה (לפחות 8 תווים)' 128 $true
    $rep = Add-Field $f 'אימות הסיסמה החדשה' 198 $true
    $cp.Cur = $cur.Box; $cp.New = $new.Box; $cp.Rep = $rep.Box
    $cp.Msg = New-ThemedLabel '' 20 268 340 24 9.5 $script:Theme.Danger
    $f.Controls.Add($cp.Msg)
    $cp.Save = New-ThemedButton 'שמור' 195 306 165 46 'primary'
    $cn = New-ThemedButton 'ביטול' 20 306 165 46 'ghost'
    $cn.DialogResult = 'Cancel'
    $f.Controls.Add($cp.Save); $f.Controls.Add($cn)
    $f.AcceptButton = $cp.Save; $f.CancelButton = $cn
    $cp.Save.Add_Click({
        $cp = $script:cp
        if ($cp.New.Text -ne $cp.Rep.Text) { $cp.Msg.Text = 'הסיסמאות החדשות אינן זהות.'; return }
        if ($cp.New.Text.Length -lt 8) { $cp.Msg.Text = 'הסיסמה החדשה קצרה מדי (מינימום 8 תווים).'; return }
        $cp.Save.Enabled = $false; $cp.Msg.Text = ''; $cp.Form.Refresh()
        try { $r = Invoke-ChangePassword $cp.Cur.Text $cp.New.Text } catch { Write-Log "change password error: $($_.Exception.Message)"; $r = New-Result $false 'אירעה שגיאה.' }
        $cp.Save.Enabled = $true
        if ($r.Ok) { $cp.Form.DialogResult = 'OK' } else { $cp.Msg.Text = $r.Message; $cp.Cur.Clear(); $cp.Cur.Focus() }
    })
    $f.Add_Shown({ $script:cp.Cur.Focus() })
    return $f
}

function Show-ChangePasswordDialog {
    $f = New-ChangePasswordForm
    $res = $f.ShowDialog(); $f.Dispose()
    return ([string]$res -eq 'OK')
}

# ---------- auto-lock settings (after every unlock + daily time) ----------

function Update-Stepper($St) { $St.Lbl.Text = ('{0:00}:{1:00}' -f $St.Hour, $St.Min) }

function Step-Time($Info) {
    $st = $script:al[$Info.Name]
    if ($Info.Part -eq 'H') { $st.Hour = ($st.Hour + 24 + $Info.Dir) % 24 }
    else { $st.Min = ($st.Min + 60 + $Info.Dir * 5) % 60 }
    Update-Stepper $st
}

# Adds "+ / HH:MM / -" controls; returns the stepper state (Hour, Min, Lbl).
function Add-Stepper($Form, [string]$Name, [int]$Y) {
    $st = @{ Hour = 0; Min = 0 }
    $st.Lbl = New-ThemedLabel '00:00' 100 ($Y + 26) 180 44 26 $script:Theme.Accent $true
    $st.Lbl.Font = New-Object System.Drawing.Font('Consolas', 26, [System.Drawing.FontStyle]::Bold)
    $st.Lbl.RightToLeft = 'No'
    $Form.Controls.Add($st.Lbl)
    $defs = @(@('H', 1, 112, $Y), @('H', -1, 112, ($Y + 72)), @('M', 1, 212, $Y), @('M', -1, 212, ($Y + 72)))
    foreach ($d in $defs) {
        $txt = '+'; if ($d[1] -lt 0) { $txt = '-' }
        $b = New-ThemedButton $txt $d[2] $d[3] 56 26 'ghost'
        $b.Tag = @{ Name = $Name; Part = $d[0]; Dir = $d[1] }
        $b.Add_Click({ param($s, $e) Step-Time $s.Tag })
        $Form.Controls.Add($b)
    }
    return $st
}

function New-AutoLockForm {
    $al = @{}
    $script:al = $al
    $f = New-ThemedForm 'WifiGate - נעילה אוטומטית' 380 540
    $al.Form = $f
    $f.Controls.Add((New-ThemedLabel 'נעילה אוטומטית' 20 12 340 34 16 $script:Theme.Text $true))

    # 1. after every unlock
    $al.DefEnable = New-Object System.Windows.Forms.CheckBox
    $al.DefEnable.Text = 'נעל אוטומטית אחרי כל פתיחה (משך: שעות:דקות)'; $al.DefEnable.SetBounds(26, 52, 330, 30)
    $al.DefEnable.Font = New-Object System.Drawing.Font('Segoe UI', 10.5); $al.DefEnable.ForeColor = $script:Theme.Text
    $al.DefEnable.BackColor = [System.Drawing.Color]::Transparent
    $f.Controls.Add($al.DefEnable)
    $al.Def = Add-Stepper $f 'Def' 90
    $al.Def.Hour = 5

    # 2. every day at a fixed time
    $al.DayEnable = New-Object System.Windows.Forms.CheckBox
    $al.DayEnable.Text = 'נעל כל יום בשעה קבועה'; $al.DayEnable.SetBounds(26, 214, 330, 30)
    $al.DayEnable.Font = New-Object System.Drawing.Font('Segoe UI', 10.5); $al.DayEnable.ForeColor = $script:Theme.Text
    $al.DayEnable.BackColor = [System.Drawing.Color]::Transparent
    $f.Controls.Add($al.DayEnable)
    $al.Day = Add-Stepper $f 'Day' 252
    $al.Day.Hour = 23

    $pw = Add-Field $f 'סיסמה לאישור השינוי' 350 $true
    $al.Pw = $pw.Box
    $al.Msg = New-ThemedLabel '' 20 418 340 22 9.5 $script:Theme.Danger
    $f.Controls.Add($al.Msg)
    $al.Save = New-ThemedButton 'שמור' 195 466 165 46 'primary'
    $cn = New-ThemedButton 'ביטול' 20 466 165 46 'ghost'
    $cn.DialogResult = 'Cancel'
    $f.Controls.Add($al.Save); $f.Controls.Add($cn)
    $f.AcceptButton = $al.Save; $f.CancelButton = $cn

    try {
        $cfg = Read-Json $script:ConfigFile
        $d = Get-Prop $cfg 'DefaultAutoLock' $null
        if ($d) {
            $al.DefEnable.Checked = [bool](Get-Prop $d 'Enabled' $false)
            $m = [int](Get-Prop $d 'Minutes' 300)
            if ($m -gt 0) { $al.Def.Hour = [int][math]::Floor($m / 60); $al.Def.Min = $m % 60 }
        }
        $dl = Get-Prop $cfg 'DailyLock' $null
        if ($dl) {
            $al.DayEnable.Checked = [bool](Get-Prop $dl 'Enabled' $false)
            $ts = [timespan]::Parse([string](Get-Prop $dl 'Time' '23:00'))
            $al.Day.Hour = [int]$ts.Hours; $al.Day.Min = [int]$ts.Minutes
        }
    } catch { }
    Update-Stepper $al.Def; Update-Stepper $al.Day

    $al.Save.Add_Click({
        $a = $script:al
        $a.Save.Enabled = $false; $a.Msg.Text = ''; $a.Form.Refresh()
        try {
            $mins = [int]($a.Def.Hour * 60 + $a.Def.Min)
            $r = Invoke-SaveAutoLockSettings $a.Pw.Text $a.DefEnable.Checked $mins $a.DayEnable.Checked ('{0:00}:{1:00}' -f $a.Day.Hour, $a.Day.Min)
        } catch { Write-Log "auto-lock settings error: $($_.Exception.Message)"; $r = New-Result $false 'אירעה שגיאה.' }
        $a.Save.Enabled = $true
        if ($r.Ok) { $a.Form.DialogResult = 'OK' } else { $a.Msg.Text = $r.Message; $a.Pw.Clear(); $a.Pw.Focus() }
    })
    return $f
}

function Show-AutoLockDialog {
    $f = New-AutoLockForm
    $res = $f.ShowDialog(); $f.Dispose()
    return ([string]$res -eq 'OK')
}
