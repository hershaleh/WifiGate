# WifiGate - Ui.ps1  (Hebrew UI toolkit: dark theme, flat rounded controls, simple dialogs)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Rgb([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }

$script:T = @{
    Bg          = (Rgb 15 23 42)
    Card        = (Rgb 30 41 59)
    CardHover   = (Rgb 51 65 85)
    Border      = (Rgb 71 85 105)
    Text        = (Rgb 226 232 240)
    Muted       = (Rgb 148 163 184)
    Accent      = (Rgb 45 212 191)
    AccentHover = (Rgb 94 234 212)
    AccentText  = (Rgb 4 30 28)
    Danger      = (Rgb 248 113 113)
    DangerHover = (Rgb 252 165 165)
    DangerText  = (Rgb 60 8 8)
    Ok          = (Rgb 74 222 128)
}

try {
    Add-Type -Namespace WG -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);'
} catch { }

function Enable-DarkTitle($Form) {
    $Form.Add_HandleCreated({
        param($s, $e)
        try { $v = 1; [void][WG.Dwm]::DwmSetWindowAttribute($s.Handle, 20, [ref]$v, 4); [void][WG.Dwm]::DwmSetWindowAttribute($s.Handle, 19, [ref]$v, 4) } catch { }
    })
}

function Set-DoubleBuffered($Control) {
    try {
        $p = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $p.SetValue($Control, $true, $null)
    } catch { }
}

function Get-RoundPath([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R) {
    $d = [single]($R * 2)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($X, $Y, $d, $d, [single]180, [single]90)
    $p.AddArc([single]($X + $W - $d), $Y, $d, $d, [single]270, [single]90)
    $p.AddArc([single]($X + $W - $d), [single]($Y + $H - $d), $d, $d, [single]0, [single]90)
    $p.AddArc($X, [single]($Y + $H - $d), $d, $d, [single]90, [single]90)
    $p.CloseFigure()
    return $p
}

function Set-Rounded($Control, [int]$Radius) {
    $path = Get-RoundPath 0 0 $Control.Width $Control.Height $Radius
    $Control.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
}

function New-ThemedForm([string]$Title, [int]$W, [int]$H) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $false
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowIcon = $false
    $f.TopMost = $true
    $f.ClientSize = New-Object System.Drawing.Size($W, $H)
    $f.BackColor = $script:T.Bg; $f.ForeColor = $script:T.Text
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    Enable-DarkTitle $f
    return $f
}

function New-ThemedLabel([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [double]$Size = 10, $Color = $null, [bool]$Bold = $false, [string]$Align = 'MiddleCenter') {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.SetBounds($X, $Y, $W, $H); $l.TextAlign = $Align
    $l.BackColor = [System.Drawing.Color]::Transparent
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', [single]$Size, $style)
    if ($Color) { $l.ForeColor = $Color } else { $l.ForeColor = $script:T.Text }
    return $l
}

function New-LinkLabel([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $l = New-ThemedLabel $Text $X $Y $W $H 10 $script:T.Muted
    $l.Cursor = [System.Windows.Forms.Cursors]::Hand
    $l.Add_MouseEnter({ param($s, $e) $s.ForeColor = $script:T.Accent })
    $l.Add_MouseLeave({ param($s, $e) $s.ForeColor = $script:T.Muted })
    return $l
}

function New-ThemedButton([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Kind = 'primary') {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.SetBounds($X, $Y, $W, $H)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    switch ($Kind) {
        'primary' { $base = $script:T.Accent;   $hover = $script:T.AccentHover; $fg = $script:T.AccentText }
        'danger'  { $base = $script:T.Danger;   $hover = $script:T.DangerHover; $fg = $script:T.DangerText }
        default   { $base = $script:T.Card;     $hover = $script:T.CardHover;   $fg = $script:T.Text }
    }
    $b.BackColor = $base; $b.ForeColor = $fg
    $b.FlatAppearance.MouseOverBackColor = $hover
    $b.FlatAppearance.MouseDownBackColor = $hover
    $b.UseVisualStyleBackColor = $false
    Set-Rounded $b 10
    return $b
}

# Returns @{ Panel; Box }. The panel draws a rounded field; the TextBox sits inside it.
function New-ThemedInput([int]$X, [int]$Y, [int]$W, [bool]$Secret = $true) {
    $H = 46
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds($X, $Y, $W, $H); $p.BackColor = $script:T.Bg
    Set-DoubleBuffered $p
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'; $tb.BackColor = $script:T.Card; $tb.ForeColor = $script:T.Text
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $tb.RightToLeft = 'No'; $tb.UseSystemPasswordChar = $Secret
    $tb.SetBounds(16, [int](($H - $tb.Height) / 2), ($W - 32), $tb.Height)
    $p.Controls.Add($tb)
    $p.Tag = $tb
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $path = Get-RoundPath 1 1 ($s.Width - 3) ($s.Height - 3) 10
        $fill = New-Object System.Drawing.SolidBrush($script:T.Card)
        $g.FillPath($fill, $path)
        $col = $script:T.Border
        if ($s.Tag.Focused) { $col = $script:T.Accent }
        $pen = New-Object System.Drawing.Pen($col, [single]1.6)
        $g.DrawPath($pen, $path)
        $fill.Dispose(); $pen.Dispose(); $path.Dispose()
    })
    $p.Add_Click({ param($s, $e) $s.Tag.Focus() })
    $tb.Add_Enter({ param($s, $e) $s.Parent.Invalidate() })
    $tb.Add_Leave({ param($s, $e) $s.Parent.Invalidate() })
    return @{ Panel = $p; Box = $tb }
}

function Add-Field($Form, [string]$Caption, [int]$Y, [bool]$Secret = $true) {
    $Form.Controls.Add((New-ThemedLabel $Caption 28 $Y 324 20 9.5 $script:T.Muted $false 'MiddleRight'))
    $in = New-ThemedInput 20 ($Y + 22) 340 $Secret
    $Form.Controls.Add($in.Panel)
    return $in
}

function Show-Message {
    param([string]$Text, [string]$Title = 'WifiGate', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    $opt = [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true; $owner.ShowInTaskbar = $false
    $owner.StartPosition = 'CenterScreen'; $owner.Size = New-Object System.Drawing.Size(0, 0)
    $owner.Show()
    try {
        $r = [System.Windows.Forms.MessageBox]::Show($owner, $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1, $opt)
    } finally { $owner.Close(); $owner.Dispose() }
    return [string]$r
}

function New-SecretDialogForm([string]$Prompt, [string]$Title = 'WifiGate') {
    $f = New-ThemedForm $Title 380 214
    $script:sd = @{ Form = $f }
    $f.Controls.Add((New-ThemedLabel $Prompt 20 16 340 46 10.5 $script:T.Text))
    $in = New-ThemedInput 20 70 340 $true
    $f.Controls.Add($in.Panel)
    $ok = New-ThemedButton 'אישור' 195 138 165 44 'primary'
    $cn = New-ThemedButton 'ביטול' 20 138 165 44 'ghost'
    $ok.DialogResult = 'OK'; $cn.DialogResult = 'Cancel'
    $f.Controls.Add($ok); $f.Controls.Add($cn)
    $f.AcceptButton = $ok; $f.CancelButton = $cn
    $script:sd.Box = $in.Box
    $f.Add_Shown({ $script:sd.Box.Focus() })
    return $f
}

function Read-SecretDialog {
    param([string]$Prompt, [string]$Title = 'WifiGate')
    $f = New-SecretDialogForm $Prompt $Title
    $res = $f.ShowDialog()
    $val = $script:sd.Box.Text
    $f.Dispose()
    if ([string]$res -eq 'OK') { return $val }
    return $null
}

# Shows the one-time recovery code in a clear, large form. Returns $true when the user confirmed writing it down.
function New-CodeDialogForm([string]$Code) {
    $f = New-ThemedForm 'WifiGate - קוד שחזור' 440 340
    $f.Controls.Add((New-ThemedLabel 'קוד השחזור שלכם' 20 18 400 34 17 $script:T.Text $true))
    $card = New-Object System.Windows.Forms.Panel
    $card.SetBounds(30, 66, 380, 84); $card.BackColor = $script:T.Card
    Set-Rounded $card 14
    $lbl = New-ThemedLabel $Code 0 0 380 84 20 $script:T.Accent $true
    $lbl.Font = New-Object System.Drawing.Font('Consolas', 20, [System.Drawing.FontStyle]::Bold)
    $lbl.RightToLeft = 'No'
    $card.Controls.Add($lbl)
    $f.Controls.Add($card)
    $f.Controls.Add((New-ThemedLabel "רשמו אותו על נייר ושמרו במקום בטוח.`nהוא פותח את ה-Wi-Fi אם שכחתם את הסיסמה או אם החלון נכשל.`nהוא לא יוצג שוב." 30 164 380 76 10 $script:T.Muted))
    $ok = New-ThemedButton 'רשמתי, המשך' 225 262 185 46 'primary'
    $cn = New-ThemedButton 'ביטול' 30 262 185 46 'ghost'
    $ok.DialogResult = 'OK'; $cn.DialogResult = 'Cancel'
    $f.Controls.Add($ok); $f.Controls.Add($cn)
    $f.AcceptButton = $ok; $f.CancelButton = $cn
    return $f
}

function Show-CodeDialog([string]$Code) {
    $f = New-CodeDialogForm $Code
    $res = $f.ShowDialog(); $f.Dispose()
    return ([string]$res -eq 'OK')
}

function Show-Report {
    param([string]$Title, [string]$Text)
    $f = New-ThemedForm $Title 720 500
    $f.FormBorderStyle = 'Sizable'; $f.MaximizeBox = $true; $f.MinimizeBox = $true
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'; $t.BorderStyle = 'None'
    $t.Dock = 'Fill'; $t.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    $t.BackColor = $script:T.Card; $t.ForeColor = $script:T.Text
    $t.Text = $Text
    $f.Padding = New-Object System.Windows.Forms.Padding(14)
    $f.Controls.Add($t)
    [void]$f.ShowDialog()
    $f.Dispose()
}
