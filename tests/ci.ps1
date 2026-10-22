# CI harness (Windows PowerShell 5.1): syntax check, logic tests, UI screenshots. Never touches adapter state.
param([string]$Root, [string]$ShotDir)
$out = New-Object System.Collections.ArrayList
function L($t) { [void]$out.Add([string]$t) }
$bad = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') { if ($Cond) { L "PASS $Name" } else { L "FAIL $Name $Detail"; $script:bad++ } }

try {
    $ErrorActionPreference = 'Stop'
    # ---- 1. syntax of every script ----
    foreach ($f in (Get-ChildItem (Join-Path $Root 'WifiGate') -Recurse -Filter *.ps1)) {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        Check ("syntax " + $f.Name) ($errs.Count -eq 0) (($errs | ForEach-Object { $_.Message + ' @' + $_.Extent.StartLineNumber }) -join '; ')
    }

    # ---- 2. logic ----
    . (Join-Path $Root 'WifiGate\src\Common.ps1')
    . (Join-Path $Root 'WifiGate\src\Ui.ps1')
    . (Join-Path $Root 'WifiGate\src\Screens.ps1')
    Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $script:DataDir | Out-Null
    $nic = @(Get-NetAdapter | Where-Object Status -eq 'Up')[0]
    Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = [string]$nic.InterfaceGuid })
    $code = New-RecoveryCode
    Write-Json $script:AuthFile ([pscustomobject]@{ Version = 1; Password = (New-SecretRecord 'OldPass123'); Recovery = (New-SecretRecord (ConvertTo-NormalCode $code)) })
    Set-State 'locked'

    Check 'unlock wrong password refused' (-not (Invoke-Unlock 'nope').Ok)
    $r = Invoke-Unlock 'OldPass123' 30
    Check 'unlock ok' $r.Ok $r.Message
    $info = Get-StateInfo
    Check 'state unlocked with auto-lock' ((-not $info.Locked) -and $info.AutoLockAt -and (($info.AutoLockAt - (Get-Date)).TotalMinutes -gt 28))
    Check 'lock not due yet' (-not (Test-LockDue))

    Set-AutoLock 0
    Check 'timer removed' ($null -eq (Get-StateInfo).AutoLockAt)
    Set-AutoLock 10
    Check 'timer set' ($null -ne (Get-StateInfo).AutoLockAt)
    $st = Read-Json $script:StateFile
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = $st.ChangedAt; AutoLockAt = (Get-Date).AddMinutes(-1).ToString('o') })
    Check 'lock due after auto-lock time passed' (Test-LockDue)

    # daily lock
    $past = (Get-Date).AddMinutes(-1).ToString('HH:mm')
    Check 'daily lock save needs correct password' (-not (Invoke-SaveDailyLock 'bad' $true $past).Ok)
    Check 'daily lock bad time rejected' (-not (Invoke-SaveDailyLock 'OldPass123' $true '25:99').Ok)
    Check 'daily lock saved' (Invoke-SaveDailyLock 'OldPass123' $true $past).Ok
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).AddHours(-2).ToString('o'); AutoLockAt = '' })
    if ((Get-Date).Hour -eq 0 -and (Get-Date).Minute -eq 0) { L 'SKIP daily lock due (midnight edge)' }
    else { Check 'daily lock due (unlocked before lock time)' (Test-LockDue) }
    Set-State 'unlocked'
    Check 'daily lock not due (unlocked after lock time)' (-not (Test-LockDue))
    [void](Invoke-SaveDailyLock 'OldPass123' $false $past)
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).AddHours(-2).ToString('o'); AutoLockAt = '' })
    Check 'daily lock disabled -> not due' (-not (Test-LockDue))
    Check 'old state file without AutoLockAt works' $true
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).ToString('o') })
    Check 'legacy state (no AutoLockAt) not due' (-not (Test-LockDue))

    # change password
    Check 'change: too short refused' (-not (Invoke-ChangePassword 'OldPass123' 'short').Ok)
    Check 'change: wrong current refused' (-not (Invoke-ChangePassword 'wrong' 'NewPass456').Ok)
    Check 'change: ok with current password' (Invoke-ChangePassword 'OldPass123' 'NewPass456').Ok
    Check 'new password unlocks' (Invoke-Unlock 'NewPass456').Ok
    Check 'old password no longer works' (-not (Invoke-Unlock 'OldPass123').Ok)
    Check 'change: recovery code accepted as current' (Invoke-ChangePassword $code 'ThirdPass789').Ok
    Check 'recovery code still valid after change' (Invoke-Recovery $code).Ok
    Check 'third password works' (Invoke-Unlock 'ThirdPass789').Ok

    # throttle
    1..5 | ForEach-Object { [void](Invoke-Unlock 'bad') }
    $t = Invoke-Unlock 'ThirdPass789'
    Check 'throttle after 5 failures' ((-not $t.Ok) -and $t.Message -match 'ניסיונות') $t.Message
    Write-Json $script:ThrottleFile ([pscustomobject]@{ Fails = 0; Until = '' })

    # ---- 3. screenshots ----
    New-Item -ItemType Directory -Force $ShotDir | Out-Null
    function Shot($Form, [string]$Name) {
        $Form.StartPosition = 'Manual'; $Form.Location = New-Object System.Drawing.Point(50, 50)
        $Form.Show(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400; [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($Form.ClientSize.Width, $Form.ClientSize.Height)
        $Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $Form.ClientSize.Width, $Form.ClientSize.Height)))
        # DrawToBitmap of a Form includes the frame; crop the client area instead
        $full = New-Object System.Drawing.Bitmap($Form.Width, $Form.Height)
        $Form.DrawToBitmap($full, (New-Object System.Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
        $full.Save((Join-Path $ShotDir ($Name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
        $full.Dispose(); $bmp.Dispose()
        $Form.Close(); $Form.Dispose()
    }
    Set-State 'locked'
    Shot (New-MainForm) 'main-locked'
    Set-State 'unlocked' ((Get-Date).AddMinutes(37).ToString('o'))
    Shot (New-MainForm) 'main-open-timer'
    Set-State 'unlocked'
    Shot (New-MainForm) 'main-open'
    Shot (New-ChangePasswordForm) 'change-password'
    Shot (New-DailyLockForm) 'daily-lock'
    Shot (New-CodeDialogForm 'AB3D-EF4G-HJ5K-LM6N-PQ7R') 'recovery-code'
    Shot (New-SecretDialogForm 'שחזור: הזינו את הסיסמה או את קוד השחזור.') 'secret-dialog'
    L 'screenshots done'
} catch {
    L ('EXCEPTION: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
    $bad++
}
Set-Content -Path (Join-Path $Root 'ci-result.txt') -Value ($out -join "`r`n") -Encoding UTF8
$text = ($out -join "`n") -replace "`r", '' -replace "`n", '%0A'
Write-Host ("::notice title=RESULT::" + $text)
if ($bad -gt 0) { exit 1 }
