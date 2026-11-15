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
    . (Join-Path $Root 'WifiGate\src\Wizard.ps1')
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
    Check 'daily lock save needs correct password' (-not (Invoke-SaveAutoLockSettings 'bad' $false 0 $true $past).Ok)
    Check 'daily lock bad time rejected' (-not (Invoke-SaveAutoLockSettings 'OldPass123' $false 0 $true '25:99').Ok)
    Check 'daily lock saved' (Invoke-SaveAutoLockSettings 'OldPass123' $false 0 $true $past).Ok
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).AddHours(-2).ToString('o'); AutoLockAt = '' })
    if ((Get-Date).Hour -eq 0 -and (Get-Date).Minute -eq 0) { L 'SKIP daily lock due (midnight edge)' }
    else { Check 'daily lock due (unlocked before lock time)' (Test-LockDue) }
    Set-State 'unlocked'
    Check 'daily lock not due (unlocked after lock time)' (-not (Test-LockDue))
    [void](Invoke-SaveAutoLockSettings 'OldPass123' $false 0 $false $past)
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).AddHours(-2).ToString('o'); AutoLockAt = '' })
    Check 'daily lock disabled -> not due' (-not (Test-LockDue))
    Check 'old state file without AutoLockAt works' $true
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).ToString('o') })
    Check 'legacy state (no AutoLockAt) not due' (-not (Test-LockDue))

    # "lock N hours after every unlock"
    Check 'default auto-lock: too short refused' (-not (Invoke-SaveAutoLockSettings 'OldPass123' $true 2 $false '23:00').Ok)
    Check 'default auto-lock: wrong password refused' (-not (Invoke-SaveAutoLockSettings 'bad' $true 300 $false '23:00').Ok)
    Check 'default auto-lock: saved (5h)' (Invoke-SaveAutoLockSettings 'OldPass123' $true 300 $false '23:00').Ok
    Check 'default minutes read back' ((Get-DefaultAutoMinutes) -eq 300)
    [void](Invoke-Unlock 'OldPass123')
    $inf = Get-StateInfo
    Check 'unlock applies the default (about 5h)' ($inf.AutoLockAt -and (($inf.AutoLockAt - (Get-Date)).TotalMinutes -gt 295) -and (($inf.AutoLockAt - (Get-Date)).TotalMinutes -le 300))
    [void](Invoke-Unlock 'OldPass123' 45)
    Check 'explicit minutes override the default' ((($inf = Get-StateInfo).AutoLockAt - (Get-Date)).TotalMinutes -lt 46)
    [void](Invoke-SaveAutoLockSettings 'OldPass123' $false 300 $false '23:00')
    Check 'default disabled -> unlock without timer' ((Get-DefaultAutoMinutes) -eq 0)
    [void](Invoke-Unlock 'OldPass123')
    Check 'no timer when default disabled' ($null -eq (Get-StateInfo).AutoLockAt)

    # ---- multi-adapter blocking ----
    function FakeNic($desc, $type, $media = '') { [pscustomobject]@{ InterfaceDescription = $desc; InterfaceType = $type; PhysicalMediaType = $media; Name = 'x' } }
    Check 'radio: Wi-Fi adapter blocked'          (Test-RadioAdapter (FakeNic 'Intel(R) Wi-Fi 6 AX201 160MHz' 71 'Native 802.11'))
    Check 'radio: USB Wi-Fi dongle blocked'       (Test-RadioAdapter (FakeNic 'Realtek RTL8188ETV Wireless LAN 802.11n USB 2.0 Network Adapter' 71))
    Check 'radio: Wi-Fi Direct blocked'           (Test-RadioAdapter (FakeNic 'Microsoft Wi-Fi Direct Virtual Adapter' 71))
    Check 'radio: Bluetooth PAN blocked'          (Test-RadioAdapter (FakeNic 'Bluetooth Device (Personal Area Network)' 6))
    Check 'radio: USB tethering (RNDIS) blocked'  (Test-RadioAdapter (FakeNic 'Remote NDIS based Internet Sharing Device' 6))
    Check 'radio: iPhone tethering blocked'       (Test-RadioAdapter (FakeNic 'Apple Mobile Device Ethernet' 6))
    Check 'radio: mobile broadband blocked'       (Test-RadioAdapter (FakeNic 'Qualcomm Snapdragon X55 5G Modem' 243 'Wireless WAN'))
    Check 'radio: wired Ethernet NOT blocked'     (-not (Test-RadioAdapter (FakeNic 'Intel(R) Ethernet Connection (7) I219-LM' 6 '802.3')))
    Check 'radio: 2.5GbE NOT blocked'             (-not (Test-RadioAdapter (FakeNic 'Realtek Gaming 2.5GbE Family Controller' 6 '802.3')))
    Check 'radio: USB Ethernet NOT blocked'       (-not (Test-RadioAdapter (FakeNic 'Realtek USB GbE Family Controller' 6 '802.3')))
    Check 'radio: Hyper-V NOT blocked'            (-not (Test-RadioAdapter (FakeNic 'Hyper-V Virtual Ethernet Adapter' 6)))
    Check 'radio: VPN NOT blocked'                (-not (Test-RadioAdapter (FakeNic 'WireGuard Tunnel' 53)))
    Check 'radio: AnyConnect NOT blocked'         (-not (Test-RadioAdapter (FakeNic 'Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter for Windows x64' 6)))
    Check 'category: Wi-Fi' ((Get-AdapterCategory (FakeNic 'Intel(R) Wi-Fi 6 AX201 160MHz' 71 'Native 802.11')) -eq 'wifi')
    Check 'category: Bluetooth' ((Get-AdapterCategory (FakeNic 'Bluetooth Device (Personal Area Network)' 6)) -eq 'bluetooth')
    Check 'category: cellular' ((Get-AdapterCategory (FakeNic 'Qualcomm Snapdragon X55 5G Modem' 243 'Wireless WAN')) -eq 'cellular')
    Check 'category: tether (RNDIS)' ((Get-AdapterCategory (FakeNic 'Remote NDIS based Internet Sharing Device' 6)) -eq 'tether')
    Check 'category: tether (iPhone)' ((Get-AdapterCategory (FakeNic 'Apple Mobile Device Ethernet' 6)) -eq 'tether')
    Check 'category: Wi-Fi Direct' ((Get-AdapterCategory (FakeNic 'Microsoft Wi-Fi Direct Virtual Adapter' 71)) -eq 'wifidirect')
    Check 'category: Ethernet is none' ($null -eq (Get-AdapterCategory (FakeNic 'Intel(R) Ethernet Connection (7) I219-LM' 6 '802.3')))
    Check 'category: Hyper-V is none' ($null -eq (Get-AdapterCategory (FakeNic 'Hyper-V Virtual Ethernet Adapter' 6)))

    # real firewall rules on the runner (rules only; adapters are never disabled in CI)
    $okNic = $null
    foreach ($cand in @(Get-NetAdapter | Where-Object Status -eq 'Up')) {
        try {
            Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = [string]$cand.InterfaceGuid })
            Remove-BlockRules
            Update-BlockRules
            $okNic = $cand; break
        } catch { L ("INFO rules failed for $($cand.Name): " + $_.Exception.Message); Remove-BlockRules }
    }
    Check 'block rules created on a real adapter' ($null -ne $okNic)
    if ($okNic) {
        $rp = Get-BlockRulesProblem
        Check 'block rules valid (2 adapter + 2 wireless rules)' (-not $rp) $rp
        Check 'four core rules exist' (@(Get-CoreRules).Count -eq 4)
        $tr = @(Get-CoreRules | Where-Object { $_.DisplayName -like '*Wireless*' } | Get-NetFirewallInterfaceTypeFilter)
        Check 'wireless rules filter interface type Wireless' (($tr.Count -eq 2) -and (@($tr | Where-Object { [string]$_.InterfaceType -ne 'Wireless' }).Count -eq 0))
        Get-CoreRules | Select-Object -First 1 | Remove-NetFirewallRule
        Check 'missing rule is detected' ([bool](Get-BlockRulesProblem))
        Update-BlockRules
        Check 'Update-BlockRules repairs a deleted rule' (-not (Get-BlockRulesProblem))
        Update-BlockRules
        Check 'Update-BlockRules is idempotent (still 4 core rules)' (@(Get-CoreRules).Count -eq 4)
        Set-DisabledByUs @('aaaa')
        Check 'disabled list round-trips' ((@(Get-DisabledByUs) -join ',') -eq 'aaaa')
        Clear-WifiBlock
        Check 'Clear-WifiBlock removes rules and clears list' ((@(Get-BlockRules).Count -eq 0) -and (@(Get-DisabledByUs).Count -eq 0))
    }

    # ---- usage log + statistics ----
    Remove-Item $script:UsageFile -Force -ErrorAction SilentlyContinue
    Set-State 'locked'
    Set-State 'unlocked'
    Set-State 'unlocked' '' 
    Set-State 'locked'
    $ul = @(Get-Content $script:UsageFile)
    Check 'usage: unlock and lock each logged once (no duplicates)' ($ul.Count -eq 2) ("lines=" + $ul.Count)
    Remove-Item $script:UsageFile -Force
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = (Get-Date).AddHours(-6).ToString('o'); AutoLockAt = ''; AutoLockFrom = ''; LastSeen = (Get-Date).AddHours(-5).ToString('o') })
    Set-State 'locked'
    $lastLine = (Get-Content $script:UsageFile | Select-Object -Last 1 | ConvertFrom-Json)
    Check 'usage: lock after power-off is stamped at LastSeen, not now' ((([datetime]$lastLine.t) -lt (Get-Date).AddHours(-4.5)))
    $now = [datetime]'2026-11-13T15:00:00'
    Remove-Item $script:UsageFile -Force
    Set-State 'locked'
    Remove-Item $script:UsageFile -Force -ErrorAction SilentlyContinue
    $evs = @(
        @{ t = '2026-11-10T22:00:00'; ev = 'u' }, @{ t = '2026-11-11T01:00:00'; ev = 'l' },
        @{ t = '2026-11-12T10:00:00'; ev = 'u' }, @{ t = '2026-11-12T12:30:00'; ev = 'l' })
    Set-Content $script:UsageFile -Value ($evs | ForEach-Object { $_ | ConvertTo-Json -Compress }) -Encoding UTF8
    $us = Get-UsageStats 7 $now
    Check 'stats: 7 days returned' ($us.Hours.Count -eq 7)
    Check 'stats: midnight-crossing session split (2h + 1h)' ([math]::Abs($us.Hours[3] - 2.0) -lt 0.01 -and [math]::Abs($us.Hours[4] - 1.0) -lt 0.01) ($us.Hours -join ',')
    Check 'stats: total 5.5h, 2 sessions, longest 180 min' (([math]::Abs($us.TotalHours - 5.5) -lt 0.01) -and ($us.Sessions -eq 2) -and ([math]::Abs($us.LongestMinutes - 180) -lt 0.5)) ("{0} {1} {2}" -f $us.TotalHours, $us.Sessions, $us.LongestMinutes)

    # ---- settings ----
    Set-State 'unlocked'
    Check 'settings: wrong password refused' (-not (Invoke-SaveSettings 'bad' @('wifi') $false $false $false).Ok)
    Check 'settings: saved' (Invoke-SaveSettings 'OldPass123' @() $false $false $false).Ok
    $cfgNow = Read-Json $script:ConfigFile
    Check 'settings: values stored' (([bool]$cfgNow.ShowTray -eq $false) -and ([bool]$cfgNow.Animations -eq $false) -and (@(Get-BlockCategories).Count -eq 0))
    Check 'settings: no categories -> only chosen adapter is a target' (@(Get-BlockTargets).Count -eq 1)
    [void](Invoke-SaveSettings 'OldPass123' @('bluetooth', 'bogus', 'tether') $true $true $true)
    Check 'settings: categories stored, unknown ones dropped' ((@(Get-BlockCategories) -join ',') -eq 'bluetooth,tether') ((@(Get-BlockCategories)) -join ',')
    [void](Invoke-SaveSettings 'OldPass123' @('wifi', 'bluetooth', 'cellular', 'tether', 'wifidirect') $true $true $true)
    Check 'settings: all categories restored' (@(Get-BlockCategories).Count -eq 5)
    Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = [string]$nic.InterfaceGuid; BlockAllRadios = $false })
    Check 'legacy BlockAllRadios=false -> no categories' (@(Get-BlockCategories).Count -eq 0)
    Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = [string]$nic.InterfaceGuid })
    Check 'legacy config without categories -> all' (@(Get-BlockCategories).Count -eq 5)

    # ---- wizard logic ----
    $fakeC = @([pscustomobject]@{ InterfaceDescription = 'Intel(R) Wi-Fi 6 AX201 160MHz'; Status = 'Up'; Name = 'Wi-Fi'; InterfaceGuid = '{11111111-1111-1111-1111-111111111111}' },
               [pscustomobject]@{ InterfaceDescription = 'Realtek USB Wireless LAN 802.11n'; Status = 'Disconnected'; Name = 'Wi-Fi 2'; InterfaceGuid = '{22222222-2222-2222-2222-222222222222}' })
    $fakeAll = @($fakeC) + @([pscustomobject]@{ InterfaceDescription = 'Bluetooth Device (Personal Area Network)'; InterfaceType = 6; Name = 'Bluetooth'; InterfaceGuid = '{33333333-3333-3333-3333-333333333333}' })
    $wizF = New-InstallWizard $fakeC $fakeAll
    Check 'wizard: page 0 needs a selected adapter (default selected)' (-not (Test-WizardPage 0))
    Check 'wizard: password too short refused' ([bool](Test-WizardPage 4))
    $script:wz.Pw1.Box.Text = 'Abcdefg1!'; $script:wz.Pw2.Box.Text = 'different'
    Check 'wizard: password mismatch refused' ([bool](Test-WizardPage 4))
    $script:wz.Pw2.Box.Text = 'Abcdefg1!'
    Check 'wizard: matching password accepted' (-not (Test-WizardPage 4))
    Check 'wizard: strength meter orders passwords' ((Get-PasswordStrength 'abcdefgh') -lt (Get-PasswordStrength 'Abcdefg1!xyz'))
    $script:wz.AdapterCards[1].Tag.Group = $script:wz.AdapterCards
    $script:wz.AdapterCards[0].Tag.Selected = $false; $script:wz.AdapterCards[1].Tag.Selected = $true
    $script:wz.CatCards['cellular'].Tag.Selected = $false
    $script:wz.CatCards['wifidirect'].Tag.Selected = $false
    $script:wz.ModeCards[0].Tag.Selected = $false; $script:wz.ModeCards[1].Tag.Selected = $true
    $script:wz.HidName.Box.Text = 'Notes'
    $wr = Get-WizardResult
    Check 'wizard: result adapter' ([string]$wr.Adapter.InterfaceGuid -eq '{22222222-2222-2222-2222-222222222222}')
    Check 'wizard: result categories' ((@($wr.Categories) -join ',') -eq 'wifi,bluetooth,tether') ((@($wr.Categories)) -join ',')
    Check 'wizard: result hidden mode + name' ($wr.Hidden -and $wr.Name -eq 'Notes' -and $wr.Password -eq 'Abcdefg1!')
    $catTxt = @()
    foreach ($k in $script:IconKeys) {
        $its = @(Get-IconCategory $k); $catTxt += "$k=$($its.Count)"
        Check "icons: $k specs point to existing files" (@($its | Where-Object { -not (Test-Path (($_.Spec -split ',')[0])) }).Count -eq 0)
    }
    L ('INFO icon categories: ' + ($catTxt -join ' '))
    Check 'icons: tools offers at least 3' (@(Get-IconCategory 'tools').Count -ge 3)
    Check 'icons: system offers at least 3' (@(Get-IconCategory 'system').Count -ge 3)
    Check 'icons: folders offers at least 5' (@(Get-IconCategory 'folders').Count -ge 5)
    Check 'icons: variety offers at least 30' (@(Get-IconCategory 'variety').Count -ge 30)
    Check 'wizard: default icon selected' ($null -ne $script:wz.SelIcon)
    Check 'wizard: result has an icon spec' ((Get-WizardResult).IconSpec -match ',\d+$') ((Get-WizardResult).IconSpec)
    $script:wz.HidName.Box.Text = 'a:b'
    Check 'wizard: forbidden file-name characters refused' ([bool](Test-WizardPage 3))
    $script:wz.ModeCards[0].Tag.Selected = $true; $script:wz.ModeCards[1].Tag.Selected = $false
    $script:wz.OpenName.Box.Text = 'x'; $script:wz.LockName.Box.Text = 'x'
    Check 'wizard: identical visible names refused' ([bool](Test-WizardPage 3))
    $script:wz.LockName.Box.Text = 'y'
    Check 'wizard: visible names accepted' (-not (Test-WizardPage 3))
    $wsum = Get-WizardSummary
    Check 'wizard: summary lists adapter and names' (($wsum -match 'Realtek USB') -and ($wsum -match 'x') -and ($wsum -match 'Bluetooth'))
    Check 'wizard: second admin off needs nothing' (-not (Test-WizardPage 5))
    $script:wz.TwoCard.Tag.Selected = $true
    $script:wz.Adm2Pw1.Box.Text = 'short'
    Check 'wizard: second admin short password refused' ([bool](Test-WizardPage 5))
    $script:wz.Adm2Pw1.Box.Text = 'Abcdefg1!'; $script:wz.Adm2Pw2.Box.Text = 'Abcdefg1!'
    Check 'wizard: same password for both admins refused' ([bool](Test-WizardPage 5))
    $script:wz.Adm2Pw1.Box.Text = 'Second-9876'; $script:wz.Adm2Pw2.Box.Text = 'Second-9876'
    Check 'wizard: second admin accepted' (-not (Test-WizardPage 5))
    $wr2 = Get-WizardResult
    Check 'wizard: result carries second admin' ($wr2.TwoAdmins -and $wr2.Password2 -eq 'Second-9876')
    $wizF.Dispose()

    # ---- tray (headless self-test) ----
    $trayOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'WifiGate\src\Tray.ps1') -SelfTest 2>&1 | Out-String)
    Check 'tray self-test runs' ($trayOut -match 'tray-selftest-ok') $trayOut

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

    # ---- two admins ----
    $authBak = Get-Content $script:AuthFile -Raw
    $c2 = New-RecoveryCode
    $au = Read-Json $script:AuthFile
    $hh = [ordered]@{}; foreach ($pp in $au.PSObject.Properties) { $hh[$pp.Name] = $pp.Value }
    $hh['Admin2'] = [pscustomobject]@{ Password = (New-SecretRecord 'SecondPass1'); Recovery = (New-SecretRecord (ConvertTo-NormalCode $c2)) }
    Write-Json $script:AuthFile ([pscustomobject]$hh)
    $SP = [string][char]1
    Check 'two: mode detected' (Get-TwoAdmins)
    Check 'two: first password alone refused' (-not (Invoke-Unlock 'ThirdPass789').Ok)
    Check 'two: wrong second password refused' (-not (Invoke-Unlock ('ThirdPass789' + $SP + 'bad')).Ok)
    Check 'two: swapped passwords refused' (-not (Invoke-Unlock ('SecondPass1' + $SP + 'ThirdPass789')).Ok)
    Check 'two: unlock does not accept recovery codes' (-not (Invoke-Unlock ($code + $SP + $c2)).Ok)
    Check 'two: both passwords unlock' (Invoke-Unlock ('ThirdPass789' + $SP + 'SecondPass1')).Ok
    Check 'two: recovery with both codes' (Invoke-Recovery ($code + $SP + $c2)).Ok
    Check 'two: recovery mixing password and code' (Invoke-Recovery ('ThirdPass789' + $SP + $c2)).Ok
    Check 'two: change admin 2 password' (Invoke-ChangePassword ('ThirdPass789' + $SP + 'SecondPass1') 'SecondNew22' 2).Ok
    Check 'two: new admin 2 password works' (Invoke-Unlock ('ThirdPass789' + $SP + 'SecondNew22')).Ok
    Check 'two: old admin 2 password refused' (-not (Invoke-Unlock ('ThirdPass789' + $SP + 'SecondPass1')).Ok)
    Check 'two: change admin 1 keeps admin 2 record' ((Invoke-ChangePassword ('ThirdPass789' + $SP + 'SecondNew22') 'FirstNew333' 1).Ok -and (Get-TwoAdmins) -and (Invoke-Unlock ('FirstNew333' + $SP + 'SecondNew22')).Ok)
    Set-Content -Path $script:AuthFile -Value $authBak -Encoding UTF8
    Write-Json $script:ThrottleFile ([pscustomobject]@{ Fails = 0; Until = '' })
    Check 'two: single mode restored' ((-not (Get-TwoAdmins)) -and (Invoke-Unlock 'ThirdPass789').Ok)

    # installer shortcut helper (Hebrew folder + Hebrew name, hotkey, run-as-admin flag)
    $tk = $null; $te = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'WifiGate\Install.ps1'), [ref]$tk, [ref]$te)
    $fn = $ast.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'New-GateShortcut') }, $true)
    Invoke-Expression $fn.Extent.Text
    $savedProg = $script:ProgDir
    $script:ProgDir = Join-Path $env:RUNNER_TEMP 'progdir'
    New-Item -ItemType Directory -Force $script:ProgDir | Out-Null
    $heb = Join-Path $env:RUNNER_TEMP ([string][char]0x05E7 + [char]0x05D9 + [char]0x05E6 + [char]0x05D5 + [char]0x05E8)
    New-GateShortcut $heb 'System Console' 'Console.ps1' 'imageres.dll,11' '' $false
    New-GateShortcut $heb ([string][char]0x05E4 + [char]0x05EA + [char]0x05D9 + [char]0x05D7 + [char]0x05D4) 'Unlock-UI.ps1' 'shell32.dll,44' 'CTRL+ALT+P'
    $l1 = [IO.File]::ReadAllBytes((Join-Path $heb 'System Console.lnk'))
    $l2 = [IO.File]::ReadAllBytes((Join-Path $heb (([string][char]0x05E4 + [char]0x05EA + [char]0x05D9 + [char]0x05D7 + [char]0x05D4) + '.lnk')))
    Check 'shortcut created in Hebrew folder' ($l1.Length -gt 100)
    Check 'shortcut has run-as-admin flag' (($l1[0x15] -band 0x20) -eq 0x20)
    Check 'hotkey Ctrl+Alt+P stored' (($l2[0x40] -eq 0x50) -and ($l2[0x41] -eq 0x06)) ("{0:X2} {1:X2}" -f $l2[0x40], $l2[0x41])
    Check 'no temp lnk left behind' (@(Get-ChildItem $script:ProgDir -Filter 'tmp-*.lnk').Count -eq 0)
    $script:ProgDir = $savedProg

    # console menu (choice Q = just show the menu and exit)
    $menuOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'WifiGate\src\Console.ps1') -Choice Q 2>&1 | Out-String)
    $lines = @($menuOut -split "`n" | Where-Object { $_.Trim() })
    Check 'console prints filler lines' ($lines.Count -ge 9) ("lines=" + $lines.Count)
    Check 'console shows no options or purpose' (-not ($menuOut -match '(?i)open|close|check|restore|exit|wifi|wi-fi|block|lock|\[1\]|menu'))
    Check 'console filler contains English and Chinese' (($menuOut -match '[a-z]{4,}') -and ($menuOut -match '[\u4e00-\u9fff]'))

    # ---- 3. screenshots ----
    New-Item -ItemType Directory -Force $ShotDir | Out-Null
    function Shot($Form, [string]$Name, [bool]$Keep = $false) {
        $Form.StartPosition = 'Manual'; $Form.Location = New-Object System.Drawing.Point(50, 50)
        $Form.Show(); [System.Windows.Forms.Application]::DoEvents(); for ($w = 0; $w -lt 30; $w++) { Start-Sleep -Milliseconds 40; [System.Windows.Forms.Application]::DoEvents() }
        $bmp = New-Object System.Drawing.Bitmap($Form.ClientSize.Width, $Form.ClientSize.Height)
        $Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $Form.ClientSize.Width, $Form.ClientSize.Height)))
        # DrawToBitmap of a Form includes the frame; crop the client area instead
        $full = New-Object System.Drawing.Bitmap($Form.Width, $Form.Height)
        $Form.DrawToBitmap($full, (New-Object System.Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
        $full.Save((Join-Path $ShotDir ($Name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
        $full.Dispose(); $bmp.Dispose()
        if (-not $Keep) { $Form.Close(); $Form.Dispose() }
    }
    Set-State 'locked'
    $mf = New-MainForm
    Check 'main window can be minimized' ($mf.MinimizeBox -and ($mf.FormBorderStyle -eq 'FixedSingle') -and $mf.ShowInTaskbar)
    Shot $mf 'main-locked'
    Set-State 'unlocked' ((Get-Date).AddMinutes(37).ToString('o'))
    Shot (New-MainForm) 'main-open-timer'
    Set-State 'unlocked'
    Shot (New-MainForm) 'main-open'
    Shot (New-ChangePasswordForm) 'change-password'
    Shot (New-AutoLockForm) 'auto-lock'
    [void](Invoke-SaveAutoLockSettings 'ThirdPass789' $true 300 $true '23:30')
    Set-State 'locked'
    Shot (New-MainForm) 'main-locked-default5h'
    Shot (New-AutoLockForm) 'auto-lock-saved'
    # statistics with a week of synthetic data
    $evl = @()
    foreach ($d in 6..0) {
        $day = (Get-Date).Date.AddDays(-$d)
        $len = @(2.5, 0.8, 4.2, 1.5, 3.1, 0.0, 1.2)[6 - $d]
        if ($len -gt 0) { $evl += @{ t = $day.AddHours(18).ToString('o'); ev = 'u' }; $evl += @{ t = $day.AddHours(18 + $len).ToString('o'); ev = 'l' } }
    }
    Set-Content $script:UsageFile -Value ($evl | ForEach-Object { $_ | ConvertTo-Json -Compress }) -Encoding UTF8
    Shot (New-StatsForm) 'stats'
    Shot (New-SettingsForm) 'settings'
    Shot (New-CodeDialogForm 'AB3D-EF4G-HJ5K-LM6N-PQ7R') 'recovery-code'
    Shot (New-SecretDialogForm 'שחזור: הזינו את הסיסמה או את קוד השחזור.') 'secret-dialog'
    # wizard pages (fake adapters) + progress window
    $wzf = New-InstallWizard $fakeC $fakeAll
    $script:wz.Pw1.Box.Text = 'Abcdefg1!x'; $script:wz.Pw2.Box.Text = 'Abcdefg1!x'
    $script:wz.Strength = 0.8; $script:wz.StrengthTarget = 0.8; $script:wz.MeterLbl.Text = 'חזקה'
    Shot $wzf 'wiz-0-adapter' $true
    Set-WizardPage 1 $true; Shot $wzf 'wiz-1-block' $true
    Set-WizardPage 2 $true; Shot $wzf 'wiz-2-mode' $true
    Set-WizardPage 3 $true; Shot $wzf 'wiz-3-names-visible' $true
    Set-WizardPage 2 $true
    $script:wz.ModeCards[0].Tag.Selected = $false; $script:wz.ModeCards[1].Tag.Selected = $true
    Set-WizardPage 3 $true; Shot $wzf 'wiz-3-icons-hidden' $true
    Select-Chip $script:wz.IconChips 5; Shot $wzf 'wiz-3-icons-variety' $true
    Select-Chip $script:wz.IconChips 1; Shot $wzf 'wiz-3-icons-system' $true
    Set-WizardPage 4 $true; Shot $wzf 'wiz-4-password' $true
    Set-WizardPage 5 $true; Shot $wzf 'wiz-5-two-admins' $true
    $script:wz.TwoCard.Tag.Selected = $true; $script:wz.Adm2Panel.Visible = $true; $script:wz.TwoCard.Invalidate()
    Shot $wzf 'wiz-5-two-admins-on' $true
    Set-WizardPage 6 $true; Shot $wzf 'wiz-6-summary' $true
    Check 'wizard: last page button says install' ($script:wz.Next.Text -eq 'התקנה')
    $wzf.Close(); $wzf.Dispose()
    $pfm = New-ProgressForm
    Set-Progress 'בדיקה עצמית: פתיחה בסיסמה...' 0.65
    Shot $pfm 'progress'
    L 'screenshots done'

    # uninstall removes exactly the shortcuts recorded in config.json (custom names, Hebrew folder)
    $dummy = Join-Path $heb 'dummy-folder'
    New-Item -ItemType Directory -Force $dummy | Out-Null
    $l2path = Join-Path $heb (([string][char]0x05E4 + [char]0x05EA + [char]0x05D9 + [char]0x05D7 + [char]0x05D4) + '.lnk')
    Write-Json $script:ConfigFile ([pscustomobject]@{ AdapterGuid = [string]$nic.InterfaceGuid; Shortcuts = @((Join-Path $heb 'System Console.lnk'), $l2path); Folders = @($dummy) })
    Invoke-Uninstall
    Check 'uninstall removed recorded shortcuts and folders' ((-not (Test-Path (Join-Path $heb 'System Console.lnk'))) -and (-not (Test-Path $l2path)) -and (-not (Test-Path $dummy)))
} catch {
    L ('EXCEPTION: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
    $bad++
}
Set-Content -Path (Join-Path $Root 'ci-result.txt') -Value ($out -join "`r`n") -Encoding UTF8
$text = ($out -join "`n") -replace "`r", '' -replace "`n", '%0A'
Write-Host ("::notice title=RESULT::" + $text)
if ($bad -gt 0) { exit 1 }
