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
    $ui.Info = $st
    if ($changed -and $ui.Shown) { $ui.Pop = 0.8 }
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
    $ui.Icon.Invalidate()
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
        } else { Set-MainMessage $r.Message 'bad'; Start-Shake }
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

function Start-Shake {
    $ui = $script:ui
    if (-not $ui.Anim) { return }
    $f = $ui.Form; $x = $f.Left
    foreach ($o in 12, -12, 9, -9, 6, -6, 3, -3, 0) { $f.Left = $x + $o; Start-Sleep -Milliseconds 20; [System.Windows.Forms.Application]::DoEvents() }
    $f.Left = $x
}

# Remaining fraction of the auto-lock countdown (1 -> 0), or -1 when there is no timer.
function Get-CountdownFraction($Info) {
    if ($null -eq $Info -or $Info.Locked -or -not $Info.AutoLockAt -or -not $Info.AutoLockFrom) { return -1.0 }
    $total = ($Info.AutoLockAt - $Info.AutoLockFrom).TotalSeconds
    if ($total -le 0) { return 0.0 }
    $rem = ($Info.AutoLockAt - (Get-Date)).TotalSeconds
    return [math]::Max(0.0, [math]::Min(1.0, $rem / $total))
}

function Paint-MainIcon($Sender, $E) {
    $ui = $script:ui
    $g = $E.Graphics; $g.SmoothingMode = 'AntiAlias'
    $cx = $Sender.Width / 2.0; $cy = $Sender.Height / 2.0
    $mix = [double]$ui.Mix
    $col = Blend $script:Theme.Danger $script:Theme.Ok $mix
    $R = 54.0 * [double]$ui.Pop
    $W = 2.0 * $R

    if ($ui.Anim -and $mix -gt 0.5) {                      # gentle pulse while open
        $p = [double]$ui.Pulse
        $rr = $R + 4 + $p * 13
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](120 * (1 - $p) * $mix), $col), [single]2)
        $g.DrawEllipse($pen, [single]($cx - $rr), [single]($cy - $rr), [single](2 * $rr), [single](2 * $rr)); $pen.Dispose()
    }
    $bg = New-Object System.Drawing.SolidBrush($script:Theme.Card)
    $g.FillEllipse($bg, [single]($cx - $R), [single]($cy - $R), [single]$W, [single]$W); $bg.Dispose()

    $frac = [double]$ui.Frac
    if ($frac -ge 0) {                                      # countdown ring
        $base = New-Object System.Drawing.Pen($script:Theme.Border, [single]3.5)
        $g.DrawEllipse($base, [single]($cx - $R), [single]($cy - $R), [single]$W, [single]$W); $base.Dispose()
        if ($frac -gt 0.002) {
            $arc = New-Object System.Drawing.Pen($script:Theme.Accent, [single]4.5)
            $arc.StartCap = 'Round'; $arc.EndCap = 'Round'
            $g.DrawArc($arc, [single]($cx - $R), [single]($cy - $R), [single]$W, [single]$W, [single]-90, [single](360 * $frac)); $arc.Dispose()
        }
    } else {
        $ring = New-Object System.Drawing.Pen($col, [single]2.5)
        $g.DrawEllipse($ring, [single]($cx - $R), [single]($cy - $R), [single]$W, [single]$W); $ring.Dispose()
    }

    $by = $cy + $W * 0.16
    $pen = New-Object System.Drawing.Pen($col, [single]($W * 0.07))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    foreach ($k in 1, 2, 3) {
        $r = $W * 0.15 * $k + $W * 0.02
        $g.DrawArc($pen, [single]($cx - $r), [single]($by - $r), [single](2 * $r), [single](2 * $r), [single]225, [single]90)
    }
    $dot = New-Object System.Drawing.SolidBrush($col)
    $d = $W * 0.085
    $g.FillEllipse($dot, [single]($cx - $d), [single]($by - $d), [single](2 * $d), [single](2 * $d))
    $dot.Dispose(); $pen.Dispose()

    if ($mix -lt 0.98) {                                    # slash fades out as it opens
        $al = [int](255 * (1 - $mix))
        $cut = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($al, $script:Theme.Card), [single]($W * 0.13))
        $sl  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($al, $col), [single]($W * 0.065))
        $cut.StartCap = 'Round'; $cut.EndCap = 'Round'; $sl.StartCap = 'Round'; $sl.EndCap = 'Round'
        $x1 = [single]($cx - $W * 0.23); $y1 = [single]($cy - $W * 0.28); $x2 = [single]($cx + $W * 0.23); $y2 = [single]($cy + $W * 0.30)
        $g.DrawLine($cut, $x1, $y1, $x2, $y2); $g.DrawLine($sl, $x1, $y1, $x2, $y2)
        $cut.Dispose(); $sl.Dispose()
    }
}

# One animation frame (~30 fps). Cheap: only the icon panel is repainted.
function Step-Anim {
    $ui = $script:ui
    if ($ui.Form.WindowState -eq 'Minimized') { return }
    $target = 0.0; if (-not $ui.Locked) { $target = 1.0 }
    if ($ui.Anim) {
        if ($ui.Form.Opacity -lt 1) { $ui.Form.Opacity = [math]::Min(1.0, $ui.Form.Opacity + 0.12) }
        if ($ui.Mix -lt $target) { $ui.Mix = [math]::Min($target, $ui.Mix + 0.07) } elseif ($ui.Mix -gt $target) { $ui.Mix = [math]::Max($target, $ui.Mix - 0.07) }
        if ($ui.Pop -lt 1) { $ui.Pop = [math]::Min(1.0, $ui.Pop + ($ui.PopSpeed * (1.02 - $ui.Pop) + 0.004)) }
        $ui.Pulse = ($ui.Pulse + 0.022) % 1.0
    } else { $ui.Mix = $target; $ui.Pop = 1.0; $ui.Form.Opacity = 1.0 }
    $ui.Frac = Get-CountdownFraction $ui.Info
    $ui.Icon.Invalidate()
}

function New-MainForm {
    $ui = @{ Locked = $true; Busy = $false; HadTimer = $false; Shown = $false; Mix = 0.0; Pop = 1.0; PopSpeed = 0.16; Pulse = 0.0; Frac = -1.0; Info = $null; Anim = $true }
    $script:ui = $ui
    try { $cfg0 = Read-Json $script:ConfigFile; $ui.Anim = [bool](Get-Prop $cfg0 'Animations' $true) } catch { }
    $f = New-ThemedForm 'WifiGate' 400 486
    $ui.Form = $f
    $f.FormBorderStyle = 'FixedSingle'     # FixedDialog has no minimize button
    $f.MinimizeBox = $true; $f.MaximizeBox = $false; $f.ShowInTaskbar = $true

    $ui.Icon = New-Object System.Windows.Forms.Panel
    $ui.Icon.SetBounds(130, 8, 140, 140); $ui.Icon.BackColor = $script:Theme.Bg
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
    $ui.LinkPw    = New-LinkLabel 'שינוי סיסמה'    301 450 94 24 9
    $ui.LinkDaily = New-LinkLabel 'נעילה אוטומטית' 204 450 94 24 9
    $ui.LinkSet   = New-LinkLabel 'הגדרות'         107 450 94 24 9
    $ui.LinkStats = New-LinkLabel 'סטטיסטיקה'      10  450 94 24 9

    foreach ($c in @($ui.Icon, $ui.Status, $ui.Sub) + $ui.LockedGroup + $ui.OpenGroup + @($ui.BtnCancelTimer, $ui.Msg, $ui.LinkPw, $ui.LinkDaily, $ui.LinkSet, $ui.LinkStats)) { $f.Controls.Add($c) }
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
    $ui.LinkSet.Add_Click({ if (Show-SettingsDialog) { Set-MainMessage 'ההגדרות נשמרו.' 'ok'; $script:ui.Anim = [bool](Get-Prop (Read-Json $script:ConfigFile) 'Animations' $true) } })
    $ui.LinkStats.Add_Click({ Show-StatsDialog })

    $ui.Timer = New-Object System.Windows.Forms.Timer
    $ui.Timer.Interval = 1000
    $ui.Timer.Add_Tick({ if (-not $script:ui.Busy) { Update-MainView } })
    $ui.AnimTimer = New-Object System.Windows.Forms.Timer
    $ui.AnimTimer.Interval = 33
    $ui.AnimTimer.Add_Tick({ Step-Anim })
    if ($ui.Anim) { $f.Opacity = 0.0 }
    $f.Add_Shown({
        $script:ui.Shown = $true
        Update-MainView
        $script:ui.Mix = 0.0; if (-not $script:ui.Locked) { $script:ui.Mix = 1.0 }
        $script:ui.Timer.Start(); $script:ui.AnimTimer.Start()
        if ($script:ui.Locked) { $script:ui.Input.Box.Focus() }
    })
    $f.Add_FormClosed({ $script:ui.Timer.Stop(); $script:ui.AnimTimer.Stop() })
    $ui.Mix = 0.0
    Update-MainView
    if (-not $ui.Locked) { $ui.Mix = 1.0 }
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
    $f = New-ThemedForm 'WifiGate - נעילה אוטומטית' 380 548
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

    $pw = Add-Field $f 'סיסמה לאישור השינוי' 364 $true
    $al.Pw = $pw.Box
    $al.Msg = New-ThemedLabel '' 20 438 340 22 9.5 $script:Theme.Danger
    $f.Controls.Add($al.Msg)
    $al.Save = New-ThemedButton 'שמור' 195 478 165 46 'primary'
    $cn = New-ThemedButton 'ביטול' 20 478 165 46 'ghost'
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

# ---------- settings ----------

function New-SettingsForm {
    $sd = @{}
    $script:setf = $sd
    $f = New-ThemedForm 'WifiGate - הגדרות' 380 640
    $sd.Form = $f
    $f.Controls.Add((New-ThemedLabel 'הגדרות' 20 10 340 34 16 $script:Theme.Text $true))
    $f.Controls.Add((New-ThemedLabel 'מה נחסם (מתאם ה-Wi-Fi הראשי נחסם תמיד)' 20 46 340 22 10 $script:Theme.Muted))
    $catDefs = @(
        @('wifi',       'מתאמי Wi-Fi נוספים (כרטיס USB)'),
        @('bluetooth',  'Bluetooth'),
        @('cellular',   'סלולר (מודם / Mobile Broadband)'),
        @('tether',     'שיתוף אינטרנט (USB / טלפון)'),
        @('wifidirect', 'Wi-Fi Direct')
    )
    $sd.Cats = @{}
    $y = 72
    foreach ($d in $catDefs) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $d[1]; $cb.SetBounds(26, $y, 330, 30)
        $cb.Font = New-Object System.Drawing.Font('Segoe UI', 10.5); $cb.ForeColor = $script:Theme.Text
        $cb.BackColor = [System.Drawing.Color]::Transparent; $cb.Checked = $true
        $f.Controls.Add($cb); $sd.Cats[$d[0]] = $cb
        $y += 32
    }
    $f.Controls.Add((New-ThemedLabel 'כללי' 20 ($y + 6) 340 22 10 $script:Theme.Muted))
    $defs = @(
        @('Tray',     'הצג אייקון במגש המערכת'),
        @('Reminder', 'תזכורת 5 דקות לפני נעילה אוטומטית'),
        @('Anim',     'הפעל אנימציות')
    )
    $y += 32
    foreach ($d in $defs) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $d[1]; $cb.SetBounds(26, $y, 330, 30)
        $cb.Font = New-Object System.Drawing.Font('Segoe UI', 10.5); $cb.ForeColor = $script:Theme.Text
        $cb.BackColor = [System.Drawing.Color]::Transparent; $cb.Checked = $true
        $f.Controls.Add($cb); $sd[$d[0]] = $cb
        $y += 32
    }
    $pw = Add-Field $f 'סיסמה לאישור השינוי' ($y + 8) $true
    $sd.Pw = $pw.Box
    $sd.Msg = New-ThemedLabel '' 20 ($y + 78) 340 22 9.5 $script:Theme.Danger
    $f.Controls.Add($sd.Msg)
    $sd.Save = New-ThemedButton 'שמור' 195 ($y + 106) 165 46 'primary'
    $cn = New-ThemedButton 'ביטול' 20 ($y + 106) 165 46 'ghost'
    $cn.DialogResult = 'Cancel'
    $f.Controls.Add($sd.Save); $f.Controls.Add($cn)
    $f.AcceptButton = $sd.Save; $f.CancelButton = $cn
    $f.ClientSize = New-Object System.Drawing.Size(380, ($y + 170))
    try {
        $cfg = Read-Json $script:ConfigFile
        $cur = @(Get-BlockCategories)
        foreach ($k in @($sd.Cats.Keys)) { $sd.Cats[$k].Checked = ($cur -contains $k) }
        $sd.Tray.Checked = [bool](Get-Prop $cfg 'ShowTray' $true)
        $sd.Reminder.Checked = [bool](Get-Prop $cfg 'Reminder' $true)
        $sd.Anim.Checked = [bool](Get-Prop $cfg 'Animations' $true)
    } catch { }
    $sd.Save.Add_Click({
        $x = $script:setf
        $x.Save.Enabled = $false; $x.Msg.Text = ''; $x.Form.Refresh()
        $sel = @($x.Cats.Keys | Where-Object { $x.Cats[$_].Checked })
        try { $r = Invoke-SaveSettings $x.Pw.Text $sel $x.Tray.Checked $x.Reminder.Checked $x.Anim.Checked }
        catch { Write-Log "settings error: $($_.Exception.Message)"; $r = New-Result $false 'אירעה שגיאה.' }
        $x.Save.Enabled = $true
        if ($r.Ok) { $x.Form.DialogResult = 'OK' } else { $x.Msg.Text = $r.Message; $x.Pw.Clear(); $x.Pw.Focus() }
    })
    return $f
}

function Show-SettingsDialog {
    $f = New-SettingsForm
    $res = $f.ShowDialog(); $f.Dispose()
    return ([string]$res -eq 'OK')
}

# ---------- statistics (animated bar chart of open hours, last 7 days) ----------

$script:DayLetters = @('א', 'ב', 'ג', 'ד', 'ה', 'ו', 'ש')     # Sunday .. Saturday

function Format-Hours([double]$H) {
    $m = [int][math]::Round($H * 60)
    return ('{0}:{1:00}' -f [math]::Floor($m / 60), ($m % 60))
}

function Paint-StatsChart($Sender, $E) {
    $st = $script:stf
    $g = $E.Graphics; $g.SmoothingMode = 'AntiAlias'
    $W = $Sender.Width; $H = $Sender.Height
    $data = $st.Data; $n = $data.Hours.Count
    $max = 1.0; foreach ($h in $data.Hours) { if ($h -gt $max) { $max = [math]::Ceiling($h) } }
    $top = 26.0; $bottom = 28.0; $chartH = $H - $top - $bottom
    $slot = ($W - 20.0) / $n; $bw = $slot * 0.56
    $gridPen = New-Object System.Drawing.Pen($script:Theme.CardHover, [single]1)
    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $muted = New-Object System.Drawing.SolidBrush($script:Theme.Muted)
    $text = New-Object System.Drawing.SolidBrush($script:Theme.Text)
    $center = New-Object System.Drawing.StringFormat; $center.Alignment = 'Center'
    foreach ($frac in 0.0, 0.5, 1.0) {
        $y = [single]($top + $chartH * (1 - $frac))
        $g.DrawLine($gridPen, 10, $y, ($W - 10), $y)
    }
    $p = [double]$st.P; $ease = 1 - [math]::Pow(1 - $p, 3)
    for ($i = 0; $i -lt $n; $i++) {
        $x = ($W - 10.0) - ($i + 1) * $slot + ($slot - $bw) / 2          # oldest on the right (Hebrew reading order)
        $val = [double]$data.Hours[$i]
        $bh = [math]::Max(0.0, ($val / $max) * $chartH * $ease)
        $isToday = ($i -eq $n - 1)
        $col = $script:Theme.Accent; if ($isToday) { $col = $script:Theme.Ok }
        if ($bh -gt 1) {
            $path = Get-RoundPath ([single]$x) ([single]($top + $chartH - $bh)) ([single]$bw) ([single]$bh) ([single][math]::Min(8.0, $bw / 2))
            $br = New-Object System.Drawing.SolidBrush($col); $g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
        }
        if ($val -gt 0.01 -and $ease -gt 0.7) {
            $g.DrawString((Format-Hours $val), $font, $text, [single]($x + $bw / 2), [single]($top + $chartH - $bh - 17), $center)
        }
        $day = $data.First.AddDays($i)
        $g.DrawString($script:DayLetters[[int]$day.DayOfWeek], $font, $muted, [single]($x + $bw / 2), [single]($H - 22), $center)
    }
    $gridPen.Dispose(); $font.Dispose(); $muted.Dispose(); $text.Dispose(); $center.Dispose()
}

function New-StatsForm {
    $st = @{ P = 0.0; Data = (Get-UsageStats 7) }
    $script:stf = $st
    $f = New-ThemedForm 'WifiGate - סטטיסטיקה' 380 440
    $st.Form = $f
    $f.Controls.Add((New-ThemedLabel 'שעות Wi-Fi פתוח, 7 ימים אחרונים' 20 14 340 30 13 $script:Theme.Text $true))
    $d = $st.Data
    $f.Controls.Add((New-ThemedLabel ('סה"כ ' + (Format-Hours $d.TotalHours) + ' שעות') 20 50 340 34 20 $script:Theme.Accent $true))
    $chart = New-Object System.Windows.Forms.Panel
    $chart.SetBounds(20, 96, 340, 220); $chart.BackColor = $script:Theme.Card
    Set-DoubleBuffered $chart
    Set-Rounded $chart 14
    $chart.Add_Paint({ param($s, $e) Paint-StatsChart $s $e })
    $f.Controls.Add($chart); $st.Chart = $chart
    $avg = 0.0; if ($d.Hours.Count -gt 0) { $avg = $d.TotalHours / $d.Hours.Count }
    $f.Controls.Add((New-ThemedLabel ('פתיחות: ' + $d.Sessions + '     ממוצע ליום: ' + (Format-Hours $avg) + '     הארוכה: ' + (Format-Hours ($d.LongestMinutes / 60.0))) 20 330 340 24 9.5 $script:Theme.Muted))
    $ok = New-ThemedButton 'סגור' 20 372 340 46 'ghost'
    $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok; $f.CancelButton = $ok
    $st.Timer = New-Object System.Windows.Forms.Timer
    $st.Timer.Interval = 16
    $st.Timer.Add_Tick({
        $x = $script:stf
        $x.P = [math]::Min(1.0, $x.P + 0.045)
        $x.Chart.Invalidate()
        if ($x.P -ge 1.0) { $x.Timer.Stop() }
    })
    $f.Add_Shown({ $script:stf.Timer.Start() })
    $f.Add_FormClosed({ $script:stf.Timer.Stop() })
    return $f
}

function Show-StatsDialog {
    $f = New-StatsForm
    [void]$f.ShowDialog(); $f.Dispose()
}
