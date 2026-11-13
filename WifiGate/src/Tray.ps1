# WifiGate - Tray.ps1 : tray icon (runs elevated in the installing user's session, started at logon).
#   shows locked/open state + time left, "open window" / "lock now" menu, reminder 5 min before auto-lock.
param([switch]$SelfTest)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) { exit }
. (Join-Path $PSScriptRoot 'Ui.ps1')

$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, ('Local\WifiGateTray'), [ref]$created)
if (-not $created -and -not $SelfTest) { exit }

try { Add-Type -Namespace WG -Name User32 -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);' } catch { }

function New-TrayIcon([bool]$Locked) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    if ($Locked) { $col = $script:Theme.Danger } else { $col = $script:Theme.Ok }
    $bg = New-Object System.Drawing.SolidBrush($script:Theme.Card)
    $g.FillEllipse($bg, 0, 0, 31, 31)
    $pen = New-Object System.Drawing.Pen($col, [single]2.8); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    foreach ($r in 6, 10.5, 15) { $g.DrawArc($pen, [single](16 - $r), [single](22 - $r), [single](2 * $r), [single](2 * $r), [single]225, [single]90) }
    $db = New-Object System.Drawing.SolidBrush($col); $g.FillEllipse($db, 13.5, 19.5, 5, 5)
    if ($Locked) {
        $cut = New-Object System.Drawing.Pen($script:Theme.Card, [single]6); $cut.StartCap = 'Round'; $cut.EndCap = 'Round'
        $sl = New-Object System.Drawing.Pen($col, [single]3); $sl.StartCap = 'Round'; $sl.EndCap = 'Round'
        $g.DrawLine($cut, 8, 6, 24, 27); $g.DrawLine($sl, 8, 6, 24, 27)
    }
    $h = $bmp.GetHicon()
    return @{ Icon = [System.Drawing.Icon]::FromHandle($h); Handle = $h }
}

function Open-MainWindow {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $PSScriptRoot 'Unlock-UI.ps1') + '"'))
}

function Update-Tray {
    $t = $script:tray
    $cfg = $null; try { $cfg = Read-Json $script:ConfigFile } catch { }
    if (-not [bool](Get-Prop $cfg 'ShowTray' $true) -and -not $SelfTest) { $t.Ni.Visible = $false; $t.Ctx.ExitThread(); return }
    $st = Get-StateInfo
    if ($null -eq $t.Locked -or $t.Locked -ne $st.Locked) {
        $new = New-TrayIcon $st.Locked
        $old = $t.Handle
        $t.Ni.Icon = $new.Icon; $t.Handle = $new.Handle
        if ($old) { try { [void][WG.User32]::DestroyIcon($old) } catch { } }
        if ($null -ne $t.Locked -and $st.Locked -and [bool](Get-Prop $cfg 'Reminder' $true)) {
            $t.Ni.ShowBalloonTip(4000, 'Wi-Fi', 'Wi-Fi נחסם', 'None')
        }
        $t.Locked = $st.Locked
        $t.Reminded = ''
    }
    $text = 'Wi-Fi חסום'
    if (-not $st.Locked) {
        $text = 'Wi-Fi פתוח'
        if ($st.AutoLockAt) {
            $left = $st.AutoLockAt - (Get-Date)
            if ($left.TotalSeconds -lt 0) { $left = [timespan]::Zero }
            $text += ' - נעילה בעוד ' + (Format-Remaining $left)
            $key = $st.AutoLockAt.ToString('o')
            if ([bool](Get-Prop $cfg 'Reminder' $true) -and $left.TotalMinutes -le 5 -and $left.TotalSeconds -gt 0 -and $t.Reminded -ne $key) {
                $t.Reminded = $key
                $t.Ni.ShowBalloonTip(8000, 'Wi-Fi', 'ה-Wi-Fi ייחסם בעוד ' + (Format-Remaining $left) + '. לחצו כדי להאריך.', 'Info')
            }
        }
    }
    if ($text.Length -gt 60) { $text = $text.Substring(0, 60) }
    if ($t.Ni.Text -ne $text) { $t.Ni.Text = $text }
    $t.Lock.Enabled = (-not $st.Locked)
}

function Format-Remaining([timespan]$Left) {
    if ($Left.TotalSeconds -lt 60) { return 'פחות מדקה' }
    $h = [int][math]::Floor($Left.TotalHours); $m = $Left.Minutes
    if ($h -gt 0) { return "$h שעות ו-$m דקות" }
    return "$m דקות"
}

$script:tray = @{ Locked = $null; Handle = $null; Reminded = '' }
$t = $script:tray
$t.Ctx = New-Object System.Windows.Forms.ApplicationContext
$t.Ni = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RightToLeft = 'Yes'; $menu.BackColor = $script:Theme.Card; $menu.ForeColor = $script:Theme.Text
$menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$miOpen = $menu.Items.Add('פתח חלון')
$t.Lock = $menu.Items.Add('נעל עכשיו')
[void]$menu.Items.Add('-')
$miHide = $menu.Items.Add('הסתר את האייקון')
$miOpen.Add_Click({ Open-MainWindow })
$t.Lock.Add_Click({ try { Invoke-Lock } catch { Write-Log "tray lock error: $($_.Exception.Message)" }; Update-Tray })
$miHide.Add_Click({ $script:tray.Ni.Visible = $false; $script:tray.Ctx.ExitThread() })
$t.Ni.ContextMenuStrip = $menu
$t.Ni.Add_DoubleClick({ Open-MainWindow })
$t.Ni.Add_BalloonTipClicked({ Open-MainWindow })

Update-Tray
$t.Ni.Visible = $true
if ($SelfTest) {
    Update-Tray
    $t.Ni.Visible = $false; $t.Ni.Dispose(); $menu.Dispose()
    Write-Output 'tray-selftest-ok'
    exit 0
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ try { Update-Tray } catch { Write-Log "tray update error: $($_.Exception.Message)" } })
$timer.Start()
[System.Windows.Forms.Application]::Run($t.Ctx)
$t.Ni.Visible = $false; $t.Ni.Dispose()
