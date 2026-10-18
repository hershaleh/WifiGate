# WifiGate - Unlock-UI.ps1  : small Hebrew window. Password + one button = unlock.

# Self-elevate (a UAC prompt appears once) because firewall/adapter changes need admin.
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
. (Join-Path $PSScriptRoot 'Ui.ps1')

$form = New-Object System.Windows.Forms.Form
$form.Text = 'WifiGate'; $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.TopMost = $true
$form.ClientSize = New-Object System.Drawing.Size(340, 215)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$status = New-Object System.Windows.Forms.Label
$status.SetBounds(20, 12, 300, 24)
$prompt = New-Object System.Windows.Forms.Label
$prompt.Text = 'סיסמה:'; $prompt.SetBounds(20, 44, 300, 22)
$box = New-Object System.Windows.Forms.TextBox
$box.UseSystemPasswordChar = $true; $box.SetBounds(20, 68, 300, 26)
$btn = New-Object System.Windows.Forms.Button
$btn.Text = 'פתח Wi-Fi'; $btn.SetBounds(20, 106, 300, 36)
$msg = New-Object System.Windows.Forms.Label
$msg.SetBounds(20, 148, 300, 24)
$relock = New-Object System.Windows.Forms.Button
$relock.Text = 'נעל Wi-Fi עכשיו'; $relock.SetBounds(20, 175, 300, 30)
$form.Controls.AddRange(@($status, $prompt, $box, $btn, $msg, $relock))
$form.AcceptButton = $btn

function Update-View {
    $mode = 'locked'
    try { $s = Read-Json $script:StateFile; if ($s -and $s.Mode -eq 'unlocked') { $mode = 'unlocked' } } catch { }
    if ($mode -eq 'unlocked') {
        $status.Text = 'מצב: Wi-Fi פתוח'; $relock.Visible = $true
    } else {
        $status.Text = 'מצב: Wi-Fi חסום'; $relock.Visible = $false
    }
}

$btn.Add_Click({
    $btn.Enabled = $false; $msg.Text = 'בודק...'; $form.Refresh()
    $pw = $box.Text; $box.Clear()
    try {
        $r = Invoke-Unlock $pw
        if ($r.Ok) {
            $msg.Text = 'פותח את המתאם...'; $form.Refresh()
            $up = Wait-AdapterUp 20 { [System.Windows.Forms.Application]::DoEvents() }
            if ($up) { $msg.Text = 'Wi-Fi נפתח ומחובר.' } else { $msg.Text = 'Wi-Fi נפתח. ההתחברות לרשת עשויה לקחת כמה שניות.' }
        } else { $msg.Text = $r.Message }
    } catch {
        Write-Log "UI unlock error: $($_.Exception.Message)"
        $msg.Text = 'אירעה שגיאה. ראו README (שחזור).'
    }
    $btn.Enabled = $true; Update-View; $box.Focus()
})

$relock.Add_Click({
    try { Invoke-Lock; $msg.Text = 'Wi-Fi נחסם.' } catch { $msg.Text = 'שגיאה בחסימה.'; Write-Log "UI lock error: $($_.Exception.Message)" }
    Update-View
})

Update-View
$form.Add_Shown({ $box.Focus() })
[void]$form.ShowDialog()
