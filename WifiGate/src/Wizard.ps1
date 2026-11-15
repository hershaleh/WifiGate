# WifiGate - Wizard.ps1 : the visual installer (Hebrew, dark theme, animated).
# Needs Ui.ps1 and Common.ps1 (Get-AdapterCategory) to be loaded first.
# Pages: 0 adapter, 1 what to block, 2 access mode, 3 names / icon, 4 password, 5 second admin (optional), 6 summary.

# ---------- reusable selectable card ----------

function New-Card([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title, [string]$Sub = '', [string]$Style = 'check', [bool]$Selected = $false, $Image = $null, [bool]$Locked = $false) {
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds($X, $Y, $W, $H); $p.BackColor = $script:Theme.Bg
    if (-not $Locked) { $p.Cursor = [System.Windows.Forms.Cursors]::Hand }
    Set-DoubleBuffered $p
    $p.Tag = @{ Title = $Title; Sub = $Sub; Style = $Style; Selected = $Selected; Image = $Image; Locked = $Locked; Hover = $false; Group = $null; OnSelect = $null }
    $p.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $p.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $p.Add_Click({
        param($s, $e)
        $c = $s.Tag
        if ($c.Locked) { return }
        if ($c.Style -eq 'check') { $c.Selected = -not $c.Selected }
        else {
            if ($c.Group) { foreach ($o in $c.Group) { $o.Tag.Selected = $false; $o.Invalidate() } }
            $c.Selected = $true
        }
        $s.Invalidate()
        if ($c.OnSelect) { & $c.OnSelect $s }
    })
    $p.Add_Paint({
        param($s, $e)
        $c = $s.Tag
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $path = Get-RoundPath 1 1 ($s.Width - 3) ($s.Height - 3) 12
        $fillCol = $script:Theme.Card
        if ($c.Hover -and -not $c.Locked) { $fillCol = $script:Theme.CardHover }
        if ($c.Selected) { $fillCol = Blend $script:Theme.Card $script:Theme.Accent 0.14 }
        $fill = New-Object System.Drawing.SolidBrush($fillCol)
        $g.FillPath($fill, $path)
        $bw = 1.2; $bc = $script:Theme.Border
        if ($c.Selected) { $bw = 2.0; $bc = $script:Theme.Accent }
        $pen = New-Object System.Drawing.Pen($bc, [single]$bw)
        $g.DrawPath($pen, $path)
        $fill.Dispose(); $pen.Dispose(); $path.Dispose()

        $sf = New-Object System.Drawing.StringFormat
        $sf.FormatFlags = [System.Drawing.StringFormatFlags]::DirectionRightToLeft
        $sf.Trimming = 'EllipsisCharacter'
        if ($c.Style -eq 'tile') {
            $sf.Alignment = 'Center'
            if ($c.Image) { $g.DrawImage($c.Image, [int](($s.Width - 32) / 2), 10, 32, 32) }
            $tb = New-Object System.Drawing.SolidBrush($script:Theme.Text)
            $f = New-Object System.Drawing.Font('Segoe UI', 8.5)
            $g.DrawString($c.Title, $f, $tb, (New-Object System.Drawing.RectangleF(4, 48, ($s.Width - 8), 36)), $sf)
            $tb.Dispose(); $f.Dispose()
        } else {
            $sf.Alignment = 'Near'                        # right edge in a right-to-left string
            $ix = $s.Width - 38; $iy = [int](($s.Height - 22) / 2)
            if ($c.Selected) { $ib = New-Object System.Drawing.SolidBrush($script:Theme.Accent) } else { $ib = New-Object System.Drawing.SolidBrush($script:Theme.Bg) }
            $ipen = New-Object System.Drawing.Pen($script:Theme.Border, [single]1.6)
            if ($c.Selected) { $ipen.Color = $script:Theme.Accent }
            if ($c.Style -eq 'radio') {
                $g.FillEllipse($ib, $ix, $iy, 22, 22); $g.DrawEllipse($ipen, $ix, $iy, 22, 22)
                if ($c.Selected) { $dot = New-Object System.Drawing.SolidBrush($script:Theme.AccentText); $g.FillEllipse($dot, ($ix + 7), ($iy + 7), 8, 8); $dot.Dispose() }
            } else {
                $rp = Get-RoundPath $ix $iy 22 22 6
                $g.FillPath($ib, $rp); $g.DrawPath($ipen, $rp); $rp.Dispose()
                if ($c.Selected) {
                    $cp = New-Object System.Drawing.Pen($script:Theme.AccentText, [single]2.4)
                    $g.DrawLines($cp, @((New-Object System.Drawing.PointF(($ix + 5), ($iy + 11))), (New-Object System.Drawing.PointF(($ix + 9.5), ($iy + 15.5))), (New-Object System.Drawing.PointF(($ix + 17), ($iy + 6.5)))))
                    $cp.Dispose()
                }
            }
            $ib.Dispose(); $ipen.Dispose()
            $tx = 16; $tw = $s.Width - 38 - 14 - $tx
            $tcol = $script:Theme.Text
            $tf = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
            $tbr = New-Object System.Drawing.SolidBrush($tcol)
            if ($c.Sub) {
                $g.DrawString($c.Title, $tf, $tbr, (New-Object System.Drawing.RectangleF($tx, 9, $tw, 26)), $sf)
                $sfn = New-Object System.Drawing.Font('Segoe UI', 9.5)
                $sbr = New-Object System.Drawing.SolidBrush($script:Theme.Muted)
                $g.DrawString($c.Sub, $sfn, $sbr, (New-Object System.Drawing.RectangleF($tx, 35, $tw, ($s.Height - 38))), $sf)
                $sfn.Dispose(); $sbr.Dispose()
            } else {
                $sf.LineAlignment = 'Center'
                $g.DrawString($c.Title, $tf, $tbr, (New-Object System.Drawing.RectangleF($tx, 0, $tw, $s.Height)), $sf)
            }
            $tf.Dispose(); $tbr.Dispose()
        }
        $sf.Dispose()
    })
    return $p
}

# ---------- helpers ----------

# 0..1 strength of a password (length + character classes)
function Get-PasswordStrength([string]$Pw) {
    if (-not $Pw) { return 0.0 }
    $cl = 0
    if ($Pw -cmatch '[a-z]') { $cl++ }
    if ($Pw -cmatch '[A-Z]') { $cl++ }
    if ($Pw -match '\d') { $cl++ }
    if ($Pw -match '[^A-Za-z0-9]') { $cl++ }
    return [math]::Min(1.0, [math]::Min($Pw.Length / 14.0, 1.0) * 0.6 + ($cl / 4.0) * 0.4)
}

# Harmless-looking system programs whose icon the shortcut can borrow. Only those present on this PC are offered.
function Get-IconChoices {
    $sys = Join-Path $env:SystemRoot 'System32'
    $defs = @(
        @('notepad.exe', 'Notepad'), @('calc.exe', 'Calculator'), @('mspaint.exe', 'Paint'), @('control.exe', 'Control Panel'),
        @('msinfo32.exe', 'System Information'), @('cleanmgr.exe', 'Disk Cleanup'), @('charmap.exe', 'Character Map'),
        @('eventvwr.exe', 'Event Viewer'), @('resmon.exe', 'Resource Monitor'), @('mstsc.exe', 'Remote Desktop'),
        @('taskmgr.exe', 'Task Manager'), @('dxdiag.exe', 'DirectX Diagnostic'), @('winver.exe', 'About Windows'), @('perfmon.exe', 'Performance Monitor')
    )
    $list = @()
    foreach ($d in $defs) {
        $path = Join-Path $sys $d[0]
        if (-not (Test-Path $path)) { $alt = Join-Path $env:SystemRoot $d[0]; if (Test-Path $alt) { $path = $alt } else { continue } }
        try { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path); $bmp = $ico.ToBitmap(); $ico.Dispose() } catch { continue }
        $list += [pscustomobject]@{ Name = $d[1]; Path = $path; Image = $bmp }
        if ($list.Count -ge 12) { break }
    }
    return $list
}

function New-WizardText([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [double]$Size, $Color, [bool]$Bold = $false) {
    return (New-ThemedLabel $Text $X $Y $W $H $Size $Color $Bold 'MiddleLeft')   # RTL form: MiddleLeft renders on the right
}

function New-WizardPage([string]$Title, [string]$Sub) {
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds(0, 0, 540, 470); $p.BackColor = $script:Theme.Bg; $p.Visible = $false
    $p.Controls.Add((New-WizardText $Title 0 0 540 34 17 $script:Theme.Text $true))
    $p.Controls.Add((New-WizardText $Sub 0 36 540 40 10 $script:Theme.Muted))
    return $p
}

# ---------- the wizard ----------

# $Cands: Wi-Fi adapters to choose from. $All: every adapter (used to count what each block option would cover).
function New-InstallWizard($Cands, $All) {
    $wz = @{ Index = 0; DotPos = 0.0; Slide = $null; Busy = $false; Cands = @($Cands); All = @($All); Strength = 0.0; StrengthTarget = 0.0; Shake = $null }
    $script:wz = $wz
    $f = New-ThemedForm 'WifiGate - התקנה' 600 680
    $wz.Form = $f

    # header: progress dots
    $dots = New-Object System.Windows.Forms.Panel
    $dots.SetBounds(0, 14, 600, 30); $dots.BackColor = $script:Theme.Bg
    Set-DoubleBuffered $dots
    $dots.Add_Paint({
        param($s, $e)
        $w = $script:wz; $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $n = 7; $gap = 30; $cx0 = 300 + ($n - 1) * $gap / 2       # page 0 is the right-most dot
        $line = New-Object System.Drawing.Pen($script:Theme.Border, [single]2)
        $g.DrawLine($line, [single]($cx0 - ($n - 1) * $gap), 15, [single]$cx0, 15)
        $done = New-Object System.Drawing.Pen($script:Theme.Accent, [single]2.5)
        $g.DrawLine($done, [single]$cx0, 15, [single]($cx0 - $w.DotPos * $gap), 15)
        for ($i = 0; $i -lt $n; $i++) {
            $x = $cx0 - $i * $gap
            if ($i -le [math]::Round($w.DotPos)) { $b = New-Object System.Drawing.SolidBrush($script:Theme.Accent) } else { $b = New-Object System.Drawing.SolidBrush($script:Theme.Card) }
            $g.FillEllipse($b, [single]($x - 7), 8, 14, 14); $b.Dispose()
        }
        $mx = $cx0 - $w.DotPos * $gap
        $halo = New-Object System.Drawing.Pen((Blend $script:Theme.Bg $script:Theme.Accent 0.5), [single]2)
        $g.DrawEllipse($halo, [single]($mx - 11), 4, 22, 22)
        $line.Dispose(); $done.Dispose(); $halo.Dispose()
    })
    $wz.Dots = $dots
    $f.Controls.Add($dots)

    $cont = New-Object System.Windows.Forms.Panel
    $cont.SetBounds(30, 60, 540, 470); $cont.BackColor = $script:Theme.Bg
    $f.Controls.Add($cont)
    $wz.Cont = $cont
    $wz.Enter = @{}
    $wz.Check = @{}

    # ---- page 0: adapter ----
    $p0 = New-WizardPage 'בחירת מתאם ה-Wi-Fi' 'זה המתאם שייחסם. ברוב המחשבים יש רק אחד.'
    $p0.AutoScroll = $true
    $wz.AdapterCards = New-Object System.Collections.ArrayList
    $y = 84
    foreach ($a in $wz.Cands) {
        $card = New-Card 2 $y 520 62 ([string]$a.InterfaceDescription) ('מצב: ' + [string]$a.Status + '   |   ' + [string]$a.Name) 'radio' ($wz.AdapterCards.Count -eq 0)
        $card.Tag.Group = $wz.AdapterCards
        [void]$wz.AdapterCards.Add($card); $p0.Controls.Add($card)
        $y += 70
    }
    $cont.Controls.Add($p0)

    # ---- page 1: what to block ----
    $p1 = New-WizardPage 'מה לחסום' 'מתאם ה-Wi-Fi שבחרתם נחסם תמיד. אפשר לחסום גם אלה (בכל חיבור, גם אם יתחברו בעתיד):'
    $wz.CatDefs = @(
        @('main',       'מתאם ה-Wi-Fi הראשי',               'תמיד חסום'),
        @('wifi',       'מתאמי Wi-Fi נוספים',               'למשל כרטיס Wi-Fi ב-USB'),
        @('bluetooth',  'Bluetooth',                         'רשת Bluetooth (PAN) ושיתוף קבצים ברשת'),
        @('cellular',   'סלולר',                             'מודם סלולרי / Mobile Broadband / 4G / 5G'),
        @('tether',     'שיתוף אינטרנט (טתרינג)',           'טלפון מחובר ב-USB, iPhone, מודמים חיצוניים'),
        @('wifidirect', 'Wi-Fi Direct',                      'חיבורי Wi-Fi ישירים בין מכשירים')
    )
    $wz.CatCards = @{}
    $y = 84
    foreach ($d in $wz.CatDefs) {
        $locked = ($d[0] -eq 'main')
        $card = New-Card 2 $y 520 56 $d[1] $d[2] 'check' $true $null $locked
        $wz.CatCards[$d[0]] = $card; $p1.Controls.Add($card)
        $y += 62
    }
    $note = New-WizardText 'כבל Ethernet, VPN ומכונות וירטואליות לא ייחסמו.' 0 ($y + 4) 540 24 9.5 $script:Theme.Muted
    $p1.Controls.Add($note)
    $cont.Controls.Add($p1)
    $wz.Enter[1] = {
        $w = $script:wz
        $chosen = ''
        foreach ($c in $w.AdapterCards) { if ($c.Tag.Selected) { $chosen = [string]$w.Cands[$w.AdapterCards.IndexOf($c)].InterfaceGuid } }
        $cnt = @{}
        foreach ($a in $w.All) {
            if ([string]$a.InterfaceGuid -eq $chosen) { continue }
            $k = Get-AdapterCategory $a
            if ($k) { if ($cnt.ContainsKey($k)) { $cnt[$k]++ } else { $cnt[$k] = 1 } }
        }
        foreach ($d in $w.CatDefs) {
            if ($d[0] -eq 'main') { continue }
            $n = 0; if ($cnt.ContainsKey($d[0])) { $n = [int]$cnt[$d[0]] }
            $tail = 'לא נמצא כרגע, ייחסם אם יתחבר'
            if ($n -gt 0) { $tail = "נמצאו כרגע: $n" }
            $w.CatCards[$d[0]].Tag.Sub = $d[2] + '   |   ' + $tail
            $w.CatCards[$d[0]].Invalidate()
        }
    }

    # ---- page 2: access mode ----
    $p2 = New-WizardPage 'איך תפעילו את החסימה' 'בחרו איך ייראו נקודות הכניסה במחשב.'
    $wz.ModeCards = New-Object System.Collections.ArrayList
    $mv = New-Card 2 84 520 118 'מצב גלוי' "קבצים רגילים בשולחן העבודה עם שמות ברורים:`nפתיחת Wi-Fi (חלון עם סיסמה) ונעילת Wi-Fi (מיידית).`nבתפריט התחל: בדיקות ושחזור." 'radio' $true
    $mh = New-Card 2 212 520 118 'מצב מוסתר' "קובץ אחד עם אייקון תמים שנראה כמו תוכנה רגילה.`nנפתח חלון טרמינל שחור עם כיתובים חסרי פשר, בלי שום אפשרויות.`nמקשים 1-4 (שלא מוצגים) פותחים, נועלים, בודקים ומשחזרים." 'radio' $false
    foreach ($m in @($mv, $mh)) { $m.Tag.Group = $wz.ModeCards; [void]$wz.ModeCards.Add($m); $p2.Controls.Add($m) }
    $wz.HotCard = New-Card 2 344 520 64 'קיצורי מקשים' 'Ctrl+Alt+P לפתיחה, Ctrl+Alt+X לנעילה (מופיעים בתפריט התחל)' 'check' $true
    $p2.Controls.Add($wz.HotCard)
    $cont.Controls.Add($p2)

    # ---- page 3: names + icon ----
    $p3 = New-WizardPage 'שמות ואייקון' ''
    $wz.P3Sub = $p3.Controls[1]
    # visible-mode panel
    $pv = New-Object System.Windows.Forms.Panel
    $pv.SetBounds(0, 84, 540, 300); $pv.BackColor = $script:Theme.Bg
    $pv.Controls.Add((New-WizardText 'שם קובץ הפתיחה' 0 0 540 22 10 $script:Theme.Muted))
    $wz.OpenName = New-ThemedInput 0 24 540 $false
    $wz.OpenName.Box.Text = 'פתיחת Wi-Fi'
    $wz.OpenName.Box.RightToLeft = 'Yes'
    $pv.Controls.Add($wz.OpenName.Panel)
    $pv.Controls.Add((New-WizardText 'שם קובץ הנעילה' 0 90 540 22 10 $script:Theme.Muted))
    $wz.LockName = New-ThemedInput 0 114 540 $false
    $wz.LockName.Box.Text = 'נעילת Wi-Fi'
    $wz.LockName.Box.RightToLeft = 'Yes'
    $pv.Controls.Add($wz.LockName.Panel)
    $wz.PanelVisible = $pv; $p3.Controls.Add($pv)
    # hidden-mode panel
    $ph = New-Object System.Windows.Forms.Panel
    $ph.SetBounds(0, 84, 540, 380); $ph.BackColor = $script:Theme.Bg
    $ph.Controls.Add((New-WizardText 'שם הקובץ בשולחן העבודה' 0 0 540 22 10 $script:Theme.Muted))
    $wz.HidName = New-ThemedInput 0 24 540 $false
    $wz.HidName.Box.Text = 'System Console'
    $ph.Controls.Add($wz.HidName.Panel)
    $ph.Controls.Add((New-WizardText 'בחרו אייקון' 0 82 540 22 10 $script:Theme.Muted))
    $wz.Icons = @(Get-IconChoices)
    $wz.IconCards = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($ic in $wz.Icons) {
        $col = $i % 4; $row = [math]::Floor($i / 4)
        $x = 540 - 2 - 128 - $col * 137
        $card = New-Card $x (110 + $row * 100) 128 92 $ic.Name '' 'tile' ($i -eq 0) $ic.Image
        $card.Tag.Group = $wz.IconCards
        $card.Tag.OnSelect = { param($c) $script:wz.HidName.Box.Text = [string]$c.Tag.Title }
        [void]$wz.IconCards.Add($card); $ph.Controls.Add($card)
        $i++
    }
    if ($wz.Icons.Count -gt 0) { $wz.HidName.Box.Text = [string]$wz.Icons[0].Name }
    $wz.PanelHidden = $ph; $p3.Controls.Add($ph)
    $cont.Controls.Add($p3)
    $wz.Enter[3] = {
        $w = $script:wz
        $hid = ([int]$w.ModeCards.IndexOf(($w.ModeCards | Where-Object { $_.Tag.Selected } | Select-Object -First 1)) -eq 1)
        $w.PanelHidden.Visible = $hid; $w.PanelVisible.Visible = -not $hid
        if ($hid) { $w.P3Sub.Text = 'קובץ אחד בשולחן העבודה. האייקון והשם נראים כמו תוכנה רגילה.' }
        else { $w.P3Sub.Text = 'שני קבצים בשולחן העבודה. אפשר לשנות את השמות.' }
    }

    # ---- page 4: password ----
    $p4 = New-WizardPage 'סיסמה' 'הסיסמה פותחת את החסימה. לפחות 8 תווים. בנוסף תקבלו קוד שחזור.'
    $p4.Controls.Add((New-WizardText 'סיסמה' 0 90 540 22 10 $script:Theme.Muted))
    $wz.Pw1 = New-ThemedInput 0 114 540 $true
    $p4.Controls.Add($wz.Pw1.Panel)
    $meter = New-Object System.Windows.Forms.Panel
    $meter.SetBounds(0, 170, 540, 10); $meter.BackColor = $script:Theme.Bg
    Set-DoubleBuffered $meter
    $meter.Add_Paint({
        param($s, $e)
        $w = $script:wz; $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $bg = New-Object System.Drawing.SolidBrush($script:Theme.Card)
        $bp = Get-RoundPath 0 0 ($s.Width - 1) 9 4; $g.FillPath($bg, $bp); $bg.Dispose(); $bp.Dispose()
        $v = [double]$w.Strength
        if ($v -gt 0.02) {
            $col = Blend $script:Theme.Danger $script:Theme.Accent $v
            $fb = New-Object System.Drawing.SolidBrush($col)
            $fp = Get-RoundPath 0 0 ([single]([math]::Max(8, ($s.Width - 1) * $v))) 9 4
            $g.FillPath($fb, $fp); $fb.Dispose(); $fp.Dispose()
        }
    })
    $wz.Meter = $meter; $p4.Controls.Add($meter)
    $wz.MeterLbl = New-WizardText '' 0 184 540 22 9.5 $script:Theme.Muted
    $p4.Controls.Add($wz.MeterLbl)
    $p4.Controls.Add((New-WizardText 'הקלידו שוב לאימות' 0 224 540 22 10 $script:Theme.Muted))
    $wz.Pw2 = New-ThemedInput 0 248 540 $true
    $p4.Controls.Add($wz.Pw2.Panel)
    $wz.Pw1.Box.Add_TextChanged({
        $w = $script:wz
        $w.StrengthTarget = Get-PasswordStrength $w.Pw1.Box.Text
        $t = $w.Pw1.Box.Text.Length
        if ($t -eq 0) { $w.MeterLbl.Text = '' }
        elseif ($w.StrengthTarget -lt 0.4) { $w.MeterLbl.Text = 'חלשה' }
        elseif ($w.StrengthTarget -lt 0.75) { $w.MeterLbl.Text = 'סבירה' }
        else { $w.MeterLbl.Text = 'חזקה' }
    })
    $cont.Controls.Add($p4)

    # ---- page 5: second admin (optional) ----
    $pa = New-WizardPage 'שני מנהלים' 'אפשר לדרוש שני אנשים לכל פתיחה: לכל מנהל סיסמה וקוד שחזור משלו.'
    $wz.TwoCard = New-Card 2 84 520 84 'הפעל שני מנהלים' "פתיחה, שחזור ושינוי הגדרות דורשים את הסיסמה של שני המנהלים.`nמי שמקליד את הסיסמה הראשונה לא יכול לפתוח לבד." 'check' $false
    $pa.Controls.Add($wz.TwoCard)
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.SetBounds(0, 184, 540, 270); $pnl.BackColor = $script:Theme.Bg; $pnl.Visible = $false
    $pnl.Controls.Add((New-WizardText 'סיסמה של המנהל השני' 0 0 540 22 10 $script:Theme.Muted))
    $wz.Adm2Pw1 = New-ThemedInput 0 24 540 $true
    $pnl.Controls.Add($wz.Adm2Pw1.Panel)
    $pnl.Controls.Add((New-WizardText 'הקלדה חוזרת לאימות' 0 90 540 22 10 $script:Theme.Muted))
    $wz.Adm2Pw2 = New-ThemedInput 0 114 540 $true
    $pnl.Controls.Add($wz.Adm2Pw2.Panel)
    $pnl.Controls.Add((New-WizardText 'מומלץ שהמנהל השני יקליד את הסיסמה בעצמו. הוא יקבל גם קוד שחזור נפרד.' 0 172 540 24 9.5 $script:Theme.Muted))
    $wz.Adm2Panel = $pnl; $pa.Controls.Add($pnl)
    $wz.TwoCard.Tag.OnSelect = { param($c) $script:wz.Adm2Panel.Visible = [bool]$c.Tag.Selected }
    $cont.Controls.Add($pa)

    # ---- page 6: summary ----
    $p6 = New-WizardPage 'סיכום' 'זה מה שייעשה. הנעילה תופעל רק אחרי בדיקה עצמית ואישור נוסף שלכם.'
    $sum = New-Object System.Windows.Forms.TextBox
    $sum.Multiline = $true; $sum.ReadOnly = $true; $sum.BorderStyle = 'None'; $sum.ScrollBars = 'Vertical'
    $sum.SetBounds(0, 84, 540, 384); $sum.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $sum.BackColor = $script:Theme.Card; $sum.ForeColor = $script:Theme.Text
    $wz.Summary = $sum; $p6.Controls.Add($sum)
    $cont.Controls.Add($p6)
    $wz.Enter[6] = { $script:wz.Summary.Text = (Get-WizardSummary); $script:wz.Summary.Select(0, 0) }

    $wz.Pages = @($p0, $p1, $p2, $p3, $p4, $pa, $p6)
    $p0.Visible = $true

    # footer
    $wz.Msg = New-ThemedLabel '' 30 540 540 24 10 $script:Theme.Danger
    $f.Controls.Add($wz.Msg)
    $wz.Next = New-ThemedButton 'הבא' 395 580 175 50 'primary'
    $wz.Back = New-ThemedButton 'חזרה' 210 580 175 50 'ghost'
    $wz.Cancel = New-LinkLabel 'ביטול' 30 590 110 30 10
    $wz.Cancel.Add_Click({ $script:wz.Form.DialogResult = 'Cancel' })
    $wz.Back.Visible = $false
    $f.Controls.Add($wz.Next); $f.Controls.Add($wz.Back); $f.Controls.Add($wz.Cancel)
    $f.CancelButton = $null; $f.AcceptButton = $wz.Next

    $wz.Next.Add_Click({
        $w = $script:wz
        if ($w.Busy) { return }
        $m = Test-WizardPage $w.Index
        if ($m) { $w.Msg.Text = $m; Start-WizardShake; return }
        $w.Msg.Text = ''
        if ($w.Index -ge 6) { $w.Form.DialogResult = 'OK'; return }
        Set-WizardPage ($w.Index + 1)
    })
    $wz.Back.Add_Click({
        $w = $script:wz
        if ($w.Busy -or $w.Index -le 0) { return }
        $w.Msg.Text = ''
        Set-WizardPage ($w.Index - 1)
    })

    # one timer drives the page slide, the progress dots and the password meter
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 15
    $tm.Add_Tick({
        $w = $script:wz
        if ($null -ne $w.Slide) {
            $sl = $w.Slide; $sl.T += 0.085
            $t = [math]::Min($sl.T, 1.0); $ease = 1 - [math]::Pow(1 - $t, 3)
            $w.Pages[$sl.To].Left = [int](-$sl.Dir * 540 * (1 - $ease))
            $w.Pages[$sl.From].Left = [int]($sl.Dir * 540 * $ease)
            if ($sl.T -ge 1.0) {
                $w.Pages[$sl.From].Visible = $false; $w.Pages[$sl.From].Left = 0
                $w.Pages[$sl.To].Left = 0
                $w.Slide = $null; $w.Busy = $false
            }
        }
        $dd = $w.Index - $w.DotPos
        if ([math]::Abs($dd) -gt 0.01) { $w.DotPos += $dd * 0.22; $w.Dots.Invalidate() }
        elseif ($w.DotPos -ne $w.Index) { $w.DotPos = [double]$w.Index; $w.Dots.Invalidate() }
        $sd = $w.StrengthTarget - $w.Strength
        if ([math]::Abs($sd) -gt 0.004) { $w.Strength += $sd * 0.2; $w.Meter.Invalidate() }
        if ($null -ne $w.Shake) {
            $k = $w.Shake; $k.N++
            $w.Form.Left = $k.X + [int]([math]::Sin($k.N * 1.6) * 7 * (1 - $k.N / 14.0))
            if ($k.N -ge 14) { $w.Form.Left = $k.X; $w.Shake = $null }
        }
    })
    $f.Add_FormClosed({ try { $script:wz.Timer.Stop(); $script:wz.Timer.Dispose() } catch { } })
    $wz.Timer = $tm
    $f.Add_Shown({ $script:wz.Timer.Start() })
    Set-WizardButtons
    return $f
}

function Start-WizardShake {
    $w = $script:wz
    if ($null -eq $w.Shake) { $w.Shake = @{ N = 0; X = $w.Form.Left } }
}

function Set-WizardButtons {
    $w = $script:wz
    $w.Back.Visible = ($w.Index -gt 0)
    if ($w.Index -ge 6) { $w.Next.Text = 'התקנה' } else { $w.Next.Text = 'הבא' }
}

function Set-WizardPage([int]$Index, [bool]$Instant = $false) {
    $w = $script:wz
    if ($Index -lt 0 -or $Index -ge $w.Pages.Count -or $Index -eq $w.Index) { return }
    if ($w.Enter.ContainsKey($Index)) { & $w.Enter[$Index] }
    $from = $w.Index; $w.Index = $Index
    Set-WizardButtons
    $to = $w.Pages[$Index]
    if ($Instant) {
        $w.Pages[$from].Visible = $false; $w.Pages[$from].Left = 0
        $to.Left = 0; $to.Visible = $true; $w.DotPos = [double]$Index; $w.Dots.Invalidate()
        return
    }
    $dir = 1; if ($Index -lt $from) { $dir = -1 }
    $to.Left = [int](-$dir * 540); $to.Visible = $true; $to.BringToFront()
    $w.Busy = $true
    $w.Slide = @{ From = $from; To = $Index; Dir = $dir; T = 0.0 }
}

# Returns an error text, or $null when the page is complete.
function Test-WizardPage([int]$Index) {
    $w = $script:wz
    switch ($Index) {
        0 { if (-not ($w.AdapterCards | Where-Object { $_.Tag.Selected })) { return 'בחרו מתאם.' } }
        3 {
            $hid = $w.ModeCards[1].Tag.Selected
            $bad = '\\/:*?"<>|'
            if ($hid) {
                $n = $w.HidName.Box.Text.Trim()
                if (-not $n) { return 'הקלידו שם לקובץ.' }
                if ($n.IndexOfAny($bad.ToCharArray()) -ge 0) { return 'השם מכיל תווים אסורים בשם קובץ.' }
            } else {
                $a = $w.OpenName.Box.Text.Trim(); $b = $w.LockName.Box.Text.Trim()
                if (-not $a -or -not $b) { return 'הקלידו שם לכל אחד מהקבצים.' }
                if ($a -eq $b) { return 'שני השמות חייבים להיות שונים.' }
                if ($a.IndexOfAny($bad.ToCharArray()) -ge 0 -or $b.IndexOfAny($bad.ToCharArray()) -ge 0) { return 'השם מכיל תווים אסורים בשם קובץ.' }
            }
        }
        4 {
            if ($w.Pw1.Box.Text.Length -lt 8) { return 'הסיסמה קצרה מדי (מינימום 8 תווים).' }
            if ($w.Pw1.Box.Text -ne $w.Pw2.Box.Text) { return 'הסיסמאות אינן זהות.' }
        }
        5 {
            if ($w.TwoCard.Tag.Selected) {
                if ($w.Adm2Pw1.Box.Text.Length -lt 8) { return 'הסיסמה של המנהל השני קצרה מדי (מינימום 8 תווים).' }
                if ($w.Adm2Pw1.Box.Text -ne $w.Adm2Pw2.Box.Text) { return 'הסיסמאות של המנהל השני אינן זהות.' }
                if ($w.Adm2Pw1.Box.Text -ceq $w.Pw1.Box.Text) { return 'שני המנהלים חייבים סיסמאות שונות.' }
            }
        }
    }
    return $null
}

# What the wizard collected (call after it returned OK).
function Get-WizardResult {
    $w = $script:wz
    $idx = 0; foreach ($c in $w.AdapterCards) { if ($c.Tag.Selected) { $idx = $w.AdapterCards.IndexOf($c) } }
    $cats = @(); foreach ($d in $w.CatDefs) { if ($d[0] -ne 'main' -and $w.CatCards[$d[0]].Tag.Selected) { $cats += $d[0] } }
    $hid = [bool]$w.ModeCards[1].Tag.Selected
    $r = @{
        Adapter = $w.Cands[$idx]; Categories = $cats; Hidden = $hid; Hotkeys = [bool]$w.HotCard.Tag.Selected
        Password = $w.Pw1.Box.Text; TwoAdmins = [bool]$w.TwoCard.Tag.Selected; Password2 = ''; Name = ''; OpenName = ''; LockName = ''; IconPath = ''
    }
    if ($r.TwoAdmins) { $r.Password2 = $w.Adm2Pw1.Box.Text }
    if ($hid) {
        $r.Name = $w.HidName.Box.Text.Trim()
        $k = 0; foreach ($c in $w.IconCards) { if ($c.Tag.Selected) { $k = $w.IconCards.IndexOf($c) } }
        if ($w.Icons.Count -gt 0) { $r.IconPath = [string]$w.Icons[$k].Path }
    } else {
        $r.OpenName = $w.OpenName.Box.Text.Trim(); $r.LockName = $w.LockName.Box.Text.Trim()
    }
    return $r
}

function Get-WizardSummary {
    $w = $script:wz
    $r = Get-WizardResult
    $catNames = @{ wifi = 'מתאמי Wi-Fi נוספים'; bluetooth = 'Bluetooth'; cellular = 'סלולר'; tether = 'שיתוף אינטרנט'; wifidirect = 'Wi-Fi Direct' }
    $blocked = @('מתאם ה-Wi-Fi הראשי: ' + [string]$r.Adapter.InterfaceDescription)
    foreach ($c in $r.Categories) { $blocked += $catNames[$c] }
    $nl = "`r`n"
    $t = 'ייחסמו:' + $nl + (($blocked | ForEach-Object { '  • ' + $_ }) -join $nl) + $nl + $nl
    if ($r.Hidden) {
        $t += 'גישה (מצב מוסתר):' + $nl + "  • קובץ אחד בשולחן העבודה: '" + $r.Name + "'" + $nl + '  • נפתח טרמינל שחור עם כיתובים חסרי פשר. מקשים: 1 פתיחה, 2 נעילה, 3 בדיקות, 4 שחזור' + $nl
    } else {
        $t += 'גישה (מצב גלוי):' + $nl + "  • בשולחן העבודה: '" + $r.OpenName + "' ו-'" + $r.LockName + "'" + $nl + '  • בתפריט התחל: בדיקות ושחזור' + $nl
    }
    if ($r.TwoAdmins) { $t += $nl + 'שני מנהלים: כל פתיחה, שחזור ושינוי הגדרות דורשים את הסיסמה של שניהם. כל מנהל מקבל קוד שחזור משלו.' + $nl }
    if ($r.Hotkeys) { $t += '  • קיצורי מקשים: Ctrl+Alt+P פתיחה, Ctrl+Alt+X נעילה' + $nl }
    $t += $nl + 'מה יותקן:' + $nl
    $t += '  • תוכנה ב-C:\Program Files\WifiGate ונתונים מוצפנים ב-C:\ProgramData\WifiGate (מנהלים ומערכת בלבד)' + $nl
    $t += '  • כללי חומת אש, וכיבוי המתאמים הנבחרים בזמן חסימה (נפתחים בפתיחה)' + $nl
    $t += '  • משימות מתוזמנות: נעילה באתחול ובהתחברות, תיקון החסימה כל דקה, ואייקון במגש המערכת' + $nl + $nl
    $t += 'לא ישונה: Ethernet, VPN, מכונות וירטואליות וחשבון המשתמש.' + $nl
    $t += 'לפני ההפעלה תתבצע בדיקה עצמית (נעילה, פתיחה ושחזור), ה-Wi-Fi יתנתק לכמה שניות ויחזור.' + $nl
    $t += 'ביטול בכל עת: שחזור (סיסמה או קוד שחזור) ואז הסרה.'
    return $t
}

# ---------- progress window used during the actual install ----------

function New-ProgressForm {
    $f = New-ThemedForm 'WifiGate - מתקין' 460 200
    $pf = @{ Form = $f; Value = 0.0; Target = 0.0; Shine = 0 }
    $script:pf = $pf
    $f.ControlBox = $false
    $f.Controls.Add((New-ThemedLabel 'מתקין...' 20 16 420 32 15 $script:Theme.Text $true))
    $pf.Text = New-ThemedLabel '' 20 58 420 28 10.5 $script:Theme.Muted
    $f.Controls.Add($pf.Text)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.SetBounds(30, 108, 400, 16); $bar.BackColor = $script:Theme.Bg
    Set-DoubleBuffered $bar
    $bar.Add_Paint({
        param($s, $e)
        $p = $script:pf; $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $bg = New-Object System.Drawing.SolidBrush($script:Theme.Card)
        $bp = Get-RoundPath 0 0 ($s.Width - 1) 15 7; $g.FillPath($bg, $bp); $bg.Dispose(); $bp.Dispose()
        $w = [single]([math]::Max(14, ($s.Width - 1) * [double]$p.Value))
        $fp = Get-RoundPath ($s.Width - 1 - $w) 0 $w 15 7           # fills from the right (RTL)
        $fb = New-Object System.Drawing.SolidBrush($script:Theme.Accent)
        $g.FillPath($fb, $fp); $fb.Dispose()
        $sx = [single](($s.Width - 1) - (($p.Shine % 60) / 60.0) * ($s.Width + 60) + 30)
        $sh = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
        $g.SetClip($fp); $g.FillRectangle($sh, $sx, 0, 26, 16); $g.ResetClip()
        $sh.Dispose(); $fp.Dispose()
    })
    $pf.Bar = $bar; $f.Controls.Add($bar)
    return $f
}

# Moves the bar smoothly to $Fraction while keeping the window responsive.
function Set-Progress([string]$Text, [double]$Fraction) {
    $p = $script:pf
    if (-not $p) { return }
    $p.Text.Text = $Text; $p.Target = $Fraction
    for ($i = 0; $i -lt 14; $i++) {
        $p.Value += ($p.Target - $p.Value) * 0.3; $p.Shine++
        $p.Bar.Invalidate(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 14
    }
    $p.Value = $p.Target; $p.Bar.Invalidate(); [System.Windows.Forms.Application]::DoEvents()
}
