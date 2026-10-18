# WifiGate - Ui.ps1  (Hebrew, right-to-left WinForms helpers)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

function Read-SecretDialog {
    param([string]$Prompt, [string]$Title = 'WifiGate')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $f.ClientSize = New-Object System.Drawing.Size(360, 150)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Prompt; $l.SetBounds(20, 15, 320, 40)
    $t = New-Object System.Windows.Forms.TextBox
    $t.UseSystemPasswordChar = $true; $t.SetBounds(20, 62, 320, 25)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'אישור'; $ok.DialogResult = 'OK'; $ok.SetBounds(20, 105, 150, 30)
    $cn = New-Object System.Windows.Forms.Button
    $cn.Text = 'ביטול'; $cn.DialogResult = 'Cancel'; $cn.SetBounds(190, 105, 150, 30)
    $f.Controls.AddRange(@($l, $t, $ok, $cn))
    $f.AcceptButton = $ok; $f.CancelButton = $cn
    $f.Add_Shown({ $t.Focus() })
    $res = $f.ShowDialog()
    $val = $t.Text
    $f.Dispose()
    if ([string]$res -eq 'OK') { return $val }
    return $null
}

function Show-Report {
    param([string]$Title, [string]$Text)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true
    $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
    $f.ClientSize = New-Object System.Drawing.Size(720, 480)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'
    $t.Dock = 'Fill'; $t.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $t.Text = $Text
    $f.Controls.Add($t)
    [void]$f.ShowDialog()
    $f.Dispose()
}
