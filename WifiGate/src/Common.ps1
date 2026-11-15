# WifiGate - Common.ps1
# Shared logic: state, password records, firewall block, unlock, recovery, tasks.
# Dot-sourced by every other script. Requires PowerShell 5.1 (built into Windows 11).

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:ProgDir      = Join-Path $env:ProgramFiles 'WifiGate'
$script:DataDir      = Join-Path $env:ProgramData 'WifiGate'
$script:AuthFile     = Join-Path $script:DataDir 'auth.json'
$script:StateFile    = Join-Path $script:DataDir 'state.json'
$script:ThrottleFile = Join-Path $script:DataDir 'throttle.json'
$script:ConfigFile   = Join-Path $script:DataDir 'config.json'
$script:SnapshotFile = Join-Path $script:DataDir 'snapshot.json'
$script:LogFile      = Join-Path $script:DataDir 'wifigate.log'
$script:DisabledFile = Join-Path $script:DataDir 'disabled.json'   # adapters this tool turned off
$script:UsageFile    = Join-Path $script:DataDir 'usage.jsonl'     # unlock/lock history for the statistics screen
$script:RuleGroup    = 'WifiGate'
$script:Iterations   = 200000
$script:DeskName     = 'System Console'     # the single Desktop shortcut
$script:StartFolder  = 'System Console'     # Start-menu folder holding the two hotkey shortcuts

# ---------- basics ----------

function Write-Log([string]$Msg) {
    try {
        if (-not (Test-Path $script:DataDir)) { return }
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 524288)) {
            Move-Item $script:LogFile ($script:LogFile + '.old') -Force
        }
        Add-Content -Path $script:LogFile -Encoding UTF8 -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg)
    } catch { }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Json([string]$Path) {
    if (Test-Path $Path) { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}

function Write-Json([string]$Path, $Obj) {
    $tmp = $Path + '.tmp'
    $Obj | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $Path -Force
}

function New-Result([bool]$Ok, [string]$Message) {
    [pscustomobject]@{ Ok = $Ok; Message = $Message }
}

function Set-State([string]$Mode, [string]$AutoLockAt = '') {
    $prev = $null
    try { $prev = Read-Json $script:StateFile } catch { }
    $now = Get-Date
    $from = ''; if ($AutoLockAt) { $from = $now.ToString('o') }
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = $Mode; ChangedAt = $now.ToString('o'); AutoLockAt = $AutoLockAt; AutoLockFrom = $from; LastSeen = $now.ToString('o') })
    Write-UsageEvent $prev $Mode $now
}

# Called every minute while unlocked: remembers the last time the machine was alive,
# so a power-off while unlocked does not count as hours of open Wi-Fi in the statistics.
function Update-LastSeen {
    $st = Read-Json $script:StateFile
    if (-not $st -or $st.Mode -ne 'unlocked') { return }
    Write-Json $script:StateFile ([pscustomobject]@{
        Mode = 'unlocked'; ChangedAt = $st.ChangedAt
        AutoLockAt = [string](Get-Prop $st 'AutoLockAt' ''); AutoLockFrom = [string](Get-Prop $st 'AutoLockFrom' '')
        LastSeen = (Get-Date).ToString('o') })
}

function Write-UsageEvent($Prev, [string]$Mode, [datetime]$Now) {
    try {
        $prevMode = ''
        if ($Prev) { $prevMode = [string](Get-Prop $Prev 'Mode' '') }
        $ev = ''; $t = $Now
        if ($Mode -eq 'unlocked' -and $prevMode -ne 'unlocked') { $ev = 'u' }
        elseif ($Mode -ne 'unlocked' -and $prevMode -eq 'unlocked') {
            $ev = 'l'
            $ls = [string](Get-Prop $Prev 'LastSeen' '')
            if ($ls) { $lsd = [datetime]$ls; if (($Now - $lsd).TotalMinutes -gt 3) { $t = $lsd } }
        }
        if (-not $ev) { return }
        if ((Test-Path $script:UsageFile) -and ((Get-Item $script:UsageFile).Length -gt 200000)) {
            $cut = (Get-Date).AddDays(-90)
            $keep = @(Get-Content $script:UsageFile -Encoding UTF8 | Where-Object { try { ([datetime]($_ | ConvertFrom-Json).t) -ge $cut } catch { $false } })
            Set-Content -Path $script:UsageFile -Value $keep -Encoding UTF8
        }
        Add-Content -Path $script:UsageFile -Encoding UTF8 -Value ((@{ t = $t.ToString('o'); ev = $ev } | ConvertTo-Json -Compress))
    } catch { Write-Log "usage log error: $($_.Exception.Message)" }
}

# Hours of open Wi-Fi per day for the last N days (index 0 = oldest), plus totals.
function Get-UsageStats([int]$Days = 7, $Now = $null) {
    if (-not $Now) { $Now = Get-Date }
    $events = @()
    if (Test-Path $script:UsageFile) {
        foreach ($line in (Get-Content $script:UsageFile -Encoding UTF8)) {
            try { $o = $line | ConvertFrom-Json; $events += [pscustomobject]@{ T = [datetime]$o.t; Ev = [string]$o.ev } } catch { }
        }
    }
    $events = @($events | Sort-Object T)
    $intervals = @(); $start = $null
    foreach ($e in $events) {
        if ($e.Ev -eq 'u' -and $null -eq $start) { $start = $e.T }
        elseif ($e.Ev -eq 'l' -and $null -ne $start) { if ($e.T -gt $start) { $intervals += [pscustomobject]@{ S = $start; E = $e.T } }; $start = $null }
    }
    $st = Get-StateInfo
    if ($null -ne $start -and -not $st.Locked) { $intervals += [pscustomobject]@{ S = $start; E = $Now } }
    $first = $Now.Date.AddDays(-($Days - 1))
    $hours = New-Object 'double[]' $Days
    $sessions = 0; $longest = 0.0
    foreach ($iv in $intervals) {
        $dur = ($iv.E - $iv.S).TotalMinutes
        if ($iv.E -ge $first) { $sessions++; if ($dur -gt $longest) { $longest = $dur } }
        for ($d = 0; $d -lt $Days; $d++) {
            $ds = $first.AddDays($d); $de = $ds.AddDays(1)
            $os = $iv.S; if ($os -lt $ds) { $os = $ds }
            $oe = $iv.E; if ($oe -gt $de) { $oe = $de }
            if ($oe -gt $os) { $hours[$d] += ($oe - $os).TotalHours }
        }
    }
    $total = 0.0; foreach ($h in $hours) { $total += $h }
    return [pscustomobject]@{ First = $first; Hours = $hours; TotalHours = $total; Sessions = $sessions; LongestMinutes = $longest }
}

# Safe property read (StrictMode throws on missing properties).
function Get-Prop($Obj, [string]$Name, $Default = $null) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $Default
}

function Set-ConfigValue([string]$Name, $Value) {
    $c = Read-Json $script:ConfigFile
    if (-not $c) { throw 'config.json missing' }
    $h = [ordered]@{}
    foreach ($p in $c.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h[$Name] = $Value
    Write-Json $script:ConfigFile ([pscustomobject]$h)
}

# For the UI: is Wi-Fi locked, and when (if ever) will it auto-lock.
function Get-StateInfo {
    $locked = $true; $at = $null; $from = $null
    try {
        $s = Read-Json $script:StateFile
        if ($s -and $s.Mode -eq 'unlocked') {
            $locked = $false
            $v = [string](Get-Prop $s 'AutoLockAt' '')
            if ($v) { $at = [datetime]$v }
            $f = [string](Get-Prop $s 'AutoLockFrom' '')
            if ($f) { $from = [datetime]$f } elseif ($at) { $from = [datetime][string](Get-Prop $s 'ChangedAt' (Get-Date).ToString('o')) }
        }
    } catch { }
    return [pscustomobject]@{ Locked = $locked; AutoLockAt = $at; AutoLockFrom = $from }
}

# ---------- adapter (always identified by GUID, never by name) ----------

function Get-AdapterByGuid([string]$Guid) {
    $a = Get-NetAdapter -ErrorAction SilentlyContinue |
         Where-Object { $_.InterfaceGuid -eq $Guid } | Select-Object -First 1
    if (-not $a) { throw "Wi-Fi adapter $Guid not found" }
    return $a
}

function Get-WifiAdapter {
    $cfg = Read-Json $script:ConfigFile
    if (-not $cfg) { throw 'config.json missing' }
    return (Get-AdapterByGuid $cfg.AdapterGuid)
}

function Wait-AdapterUp([int]$Seconds = 20, [scriptblock]$Pump = $null) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if ((Get-WifiAdapter).Status -eq 'Up') { return $true }
        if ($Pump) { & $Pump }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# ---------- which adapters get blocked ----------

# Categories the user can choose to block (the chosen main Wi-Fi adapter is always blocked).
$script:BlockCategories = @('wifi', 'bluetooth', 'cellular', 'tether', 'wifidirect')

# wifi = any other Wi-Fi adapter (e.g. USB dongle), bluetooth, cellular = mobile broadband, tether = USB/phone internet sharing,
# wifidirect = Wi-Fi Direct virtual adapters. Wired Ethernet, VPN and virtual-machine adapters return $null (never blocked).
function Get-AdapterCategory($A) {
    $d = [string](Get-Prop $A 'InterfaceDescription' '')
    if ($d -match 'Wi-?Fi Direct') { return 'wifidirect' }
    if ($d -match 'Hyper-V|VMware|VirtualBox|TAP-|TAP Windows|Npcap|Loopback|WAN Miniport|VPN|WireGuard|OpenVPN|Tailscale|ZeroTier|AnyConnect') { return $null }
    $type = [int](Get-Prop $A 'InterfaceType' 0)
    $media = [string](Get-Prop $A 'PhysicalMediaType' '')
    if ($d -match 'Bluetooth' -or $media -match 'Bluetooth') { return 'bluetooth' }
    if ($type -in 243, 244 -or $media -match 'WiMax' -or $d -match 'Mobile Broadband|MBIM|Cellular') { return 'cellular' }
    if ($d -match 'Remote NDIS|RNDIS|Tethering|Apple Mobile Device Ethernet') { return 'tether' }
    if ($type -eq 71 -or $media -match '802\.11|Wireless' -or $d -match 'Wi-?Fi|Wireless|WLAN|802\.11') { return 'wifi' }
    return $null
}

function Test-RadioAdapter($A) { return [bool](Get-AdapterCategory $A) }

# The categories to block besides the main adapter. Older installs stored a single BlockAllRadios flag.
function Get-BlockCategories {
    $cfg = Read-Json $script:ConfigFile
    $c = Get-Prop $cfg 'BlockCategories' $null
    if ($null -ne $c) { return @($c | ForEach-Object { [string]$_ }) }
    if ([bool](Get-Prop $cfg 'BlockAllRadios' $true)) { return @($script:BlockCategories) }
    return @()
}

# The chosen Wi-Fi adapter (always) + every other adapter of a chosen category currently present.
function Get-BlockTargets {
    $map = [ordered]@{}
    $p = Get-WifiAdapter
    $map[[string]$p.InterfaceGuid] = $p
    $cats = @(Get-BlockCategories)
    if ($cats.Count -gt 0) {
        foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $c = Get-AdapterCategory $a
            if ($c -and ($cats -contains $c) -and -not $map.Contains([string]$a.InterfaceGuid)) { $map[[string]$a.InterfaceGuid] = $a }
        }
    }
    return @($map.Values)
}

function Get-DisabledByUs {
    $d = Read-Json $script:DisabledFile
    if ($d -and $d.PSObject.Properties['Guids']) { return @($d.Guids | ForEach-Object { [string]$_ }) }
    return @()
}
function Set-DisabledByUs($Guids) { Write-Json $script:DisabledFile ([pscustomobject]@{ Guids = @($Guids) }) }

# ---------- firewall block ----------

function Get-BlockRules {
    return @(Get-NetFirewallRule -DisplayName 'WifiGate block*' -ErrorAction SilentlyContinue)
}

# Windows Firewall may store the interface filter either as the alias (name) or as the adapter's LUID number.
function Get-AdapterFilterIds($Adapter) {
    $ids = @([string]$Adapter.Name)
    foreach ($pr in $Adapter.PSObject.Properties) {          # the LUID property is named NetLuid
        if ($pr.Name -eq 'NetLuid' -or $pr.Name -eq 'InterfaceLuid') { $ids += [string]$pr.Value }
    }
    return @($ids)
}

# Returns $null when the block rules are correct, otherwise a text describing what is wrong.
# Expected: 2 alias rules (in/out) covering every target adapter + 2 "any wireless interface" rules (in/out).
function Get-BlockRulesProblem([string]$Alias = '') {
    $targets = @(Get-BlockTargets)
    $rules = @(Get-BlockRules)
    $aliasRules = @($rules | Where-Object { $_.DisplayName -notlike '*Wireless*' })
    $typeRules  = @($rules | Where-Object { $_.DisplayName -like '*Wireless*' })
    if ($aliasRules.Count -ne 2 -or $typeRules.Count -ne 2) { return "נמצאו $($aliasRules.Count) כללי מתאם ו-$($typeRules.Count) כללי אלחוט, ציפיתי ל-2 ו-2" }
    foreach ($r in $rules) {
        if ([string]$r.Enabled -ne 'True') { return "הכלל '$($r.DisplayName)' לא פעיל (Enabled=$($r.Enabled))" }
        if ([string]$r.Action -ne 'Block') { return "הכלל '$($r.DisplayName)' אינו חוסם (Action=$($r.Action))" }
    }
    foreach ($grp in @($aliasRules, $typeRules)) {
        $dirs = (@($grp | ForEach-Object { [string]$_.Direction }) | Sort-Object) -join ','
        if ($dirs -ne 'Inbound,Outbound') { return "כיווני הכללים: $dirs" }
    }
    foreach ($r in $aliasRules) {
        $f = $r | Get-NetFirewallInterfaceFilter
        if (-not $f) { return "לכלל '$($r.DisplayName)' אין סינון מתאם" }
        $al = @($f.InterfaceAlias | ForEach-Object { [string]$_ })
        foreach ($t in $targets) {
            $ids = Get-AdapterFilterIds $t
            if (@($al | Where-Object { $ids -contains $_ }).Count -eq 0) { return "המתאם '$($t.Name)' לא מכוסה בכלל (סינון: [$($al -join ',')])" }
        }
    }
    foreach ($r in $typeRules) {
        $tf = $r | Get-NetFirewallInterfaceTypeFilter
        if (-not $tf -or [string]$tf.InterfaceType -ne 'Wireless') { return "הכלל '$($r.DisplayName)' אינו מסנן אלחוט" }
    }
    return $null
}

function Test-BlockRulesValid([string]$Alias = '') { return (-not (Get-BlockRulesProblem $Alias)) }

# Creates/repairs the firewall rules only (no adapter changes). Idempotent.
function Update-BlockRules {
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
    if (-not (Get-BlockRulesProblem)) { return }
    Get-BlockRules | Remove-NetFirewallRule
    $aliases = @(Get-BlockTargets | ForEach-Object { [string]$_.Name })
    $desc = 'WifiGate: blocks all traffic on wireless/cellular interfaces until unlocked.'
    foreach ($d in 'Outbound', 'Inbound') {
        try {
            New-NetFirewallRule -DisplayName ('WifiGate block ' + $d) -Group $script:RuleGroup -Description $desc `
                -Direction $d -Action Block -InterfaceAlias $aliases -Profile Any -Enabled True | Out-Null
        } catch {
            Write-Log "alias rule failed for [$($aliases -join ',')]: $($_.Exception.Message) - falling back to the chosen adapter only"
            New-NetFirewallRule -DisplayName ('WifiGate block ' + $d) -Group $script:RuleGroup -Description $desc `
                -Direction $d -Action Block -InterfaceAlias $aliases[0] -Profile Any -Enabled True | Out-Null
        }
        New-NetFirewallRule -DisplayName ('WifiGate block Wireless ' + $d) -Group $script:RuleGroup -Description $desc `
            -Direction $d -Action Block -InterfaceType Wireless -Profile Any -Enabled True | Out-Null
    }
    Write-Log "firewall rules (re)created for: $($aliases -join ', ')"
}

# Idempotent: makes sure the block is in place (rules + target adapters turned off).
function Set-WifiBlock {
    Update-BlockRules
    $targets = @(Get-BlockTargets)
    $ours = @(Get-DisabledByUs)
    foreach ($a in $targets) {
        if ($a.Status -ne 'Disabled') {
            if ($ours -notcontains [string]$a.InterfaceGuid) { $ours += [string]$a.InterfaceGuid }
            Set-DisabledByUs $ours
            try { Disable-NetAdapter -Name $a.Name -Confirm:$false; Write-Log "adapter disabled: $($a.Name)" } catch { Write-Log "disable failed for $($a.Name): $($_.Exception.Message)" }
        }
    }
    # adapters we turned off earlier that are no longer targets (setting changed): give them back
    $targetGuids = @($targets | ForEach-Object { [string]$_.InterfaceGuid })
    $still = @()
    foreach ($g in $ours) {
        if ($targetGuids -contains $g) { $still += $g; continue }
        try { $x = Get-AdapterByGuid $g; if ($x.Status -eq 'Disabled') { Enable-NetAdapter -Name $x.Name -Confirm:$false } } catch { }
    }
    if ($still.Count -ne $ours.Count) { Set-DisabledByUs $still }
}

function Clear-WifiBlock {
    Get-BlockRules | Remove-NetFirewallRule
    $a = Get-WifiAdapter
    if ($a.Status -eq 'Disabled') { Enable-NetAdapter -Name $a.Name -Confirm:$false }
    foreach ($g in @(Get-DisabledByUs)) {
        try { $x = Get-AdapterByGuid $g; if ($x.Status -eq 'Disabled') { Enable-NetAdapter -Name $x.Name -Confirm:$false } } catch { }
    }
    Set-DisabledByUs @()
}

# State is written BEFORE acting when locking (fail closed).
function Invoke-Lock {
    Set-State 'locked'
    Set-WifiBlock
    Write-Log 'locked'
}

# ---------- secrets (PBKDF2-SHA256, salted, constant-time compare) ----------

function New-SecretRecord([string]$Plain) {
    $salt = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.Dispose()
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($Plain, $salt, $script:Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $hash = $kdf.GetBytes(32); $kdf.Dispose()
    [pscustomobject]@{
        Alg = 'PBKDF2-SHA256'; Iter = $script:Iterations
        Salt = [Convert]::ToBase64String($salt); Hash = [Convert]::ToBase64String($hash)
    }
}

function Test-SecretRecord([string]$Plain, $Rec) {
    if (-not $Rec) { return $false }
    $salt = [Convert]::FromBase64String($Rec.Salt)
    $exp  = [Convert]::FromBase64String($Rec.Hash)
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($Plain, $salt, [int]$Rec.Iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $got = $kdf.GetBytes($exp.Length); $kdf.Dispose()
    $diff = 0
    for ($i = 0; $i -lt $exp.Length; $i++) { $diff = $diff -bor ($got[$i] -bxor $exp[$i]) }
    return ($diff -eq 0)
}

function New-RecoveryCode {
    $alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'   # 32 symbols -> no modulo bias with bytes
    $bytes = New-Object byte[] 20
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes); $rng.Dispose()
    $s = -join ($bytes | ForEach-Object { $alpha[$_ % 32] })
    return ($s -replace '(.{4})(?=.)', '$1-')
}

function ConvertTo-NormalCode([string]$Code) { return (($Code.ToUpper()) -replace '[\s-]', '') }

# ---------- unlock / recovery ----------

# ---------- authentication (shared throttle) ----------

function Get-ThrottleWait {
    $t = Read-Json $script:ThrottleFile
    if ($t -and $t.Until -and ([datetime]$t.Until) -gt (Get-Date)) {
        return ([int]((([datetime]$t.Until) - (Get-Date)).TotalSeconds) + 1)
    }
    return 0
}

function Register-AuthFailure {
    $t = Read-Json $script:ThrottleFile
    $f = 1; if ($t) { $f = [int]$t.Fails + 1 }
    $until = ''
    if ($f -ge 5) { $until = (Get-Date).AddSeconds([math]::Min(30 * ($f - 4), 600)).ToString('o') }
    Write-Json $script:ThrottleFile ([pscustomobject]@{ Fails = $f; Until = $until })
    Write-Log "auth failed (#$f)"
}

# Checks the password (and, if allowed, the recovery code) with brute-force throttling.
function Test-AuthSecret([string]$Secret, [bool]$AllowRecovery = $false) {
    $w = Get-ThrottleWait
    if ($w -gt 0) { return (New-Result $false "יותר מדי ניסיונות. נסו שוב בעוד $w שניות.") }
    $auth = Read-Json $script:AuthFile
    $ok = $false
    if ($auth) {
        $ok = Test-SecretRecord $Secret $auth.Password
        if (-not $ok -and $AllowRecovery) { $ok = Test-SecretRecord (ConvertTo-NormalCode $Secret) $auth.Recovery }
    }
    if (-not $ok) {
        Register-AuthFailure
        if ($AllowRecovery) { return (New-Result $false 'הסיסמה או קוד השחזור שגויים.') }
        return (New-Result $false 'הסיסמה שגויה.')
    }
    Write-Json $script:ThrottleFile ([pscustomobject]@{ Fails = 0; Until = '' })
    return (New-Result $true '')
}

# ---------- unlock / recovery ----------

# AutoLockMinutes > 0: the Wi-Fi locks itself again after that many minutes (enforced by the Tick task).
function Invoke-Unlock([string]$Password, [int]$AutoLockMinutes = 0) {
    $a = Test-AuthSecret $Password $false
    if (-not $a.Ok) { return $a }
    if ($AutoLockMinutes -le 0) { $AutoLockMinutes = Get-DefaultAutoMinutes }   # "lock N hours after every unlock" setting
    Clear-WifiBlock                 # remove rules + enable adapter
    $at = ''
    if ($AutoLockMinutes -gt 0) { $at = (Get-Date).AddMinutes($AutoLockMinutes).ToString('o') }
    Set-State 'unlocked' $at
    Write-Log "unlocked with password (auto-lock: $AutoLockMinutes min)"
    return (New-Result $true 'Wi-Fi נפתח.')
}

# While unlocked: set (Minutes > 0) or remove (0) the auto-lock time. Keeps the original unlock time.
function Set-AutoLock([int]$Minutes) {
    $st = Read-Json $script:StateFile
    if (-not $st -or $st.Mode -ne 'unlocked') { throw 'Wi-Fi is not unlocked' }
    $at = ''; $from = ''
    if ($Minutes -gt 0) { $at = (Get-Date).AddMinutes($Minutes).ToString('o'); $from = (Get-Date).ToString('o') }
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = 'unlocked'; ChangedAt = $st.ChangedAt; AutoLockAt = $at; AutoLockFrom = $from; LastSeen = (Get-Date).ToString('o') })
    Write-Log "auto-lock set: $Minutes min"
}

function Invoke-ChangePassword([string]$Current, [string]$New) {
    if ($New.Length -lt 8) { return (New-Result $false 'הסיסמה החדשה קצרה מדי (מינימום 8 תווים).') }
    $a = Test-AuthSecret $Current $true
    if (-not $a.Ok) { return $a }
    $auth = Read-Json $script:AuthFile
    Write-Json $script:AuthFile ([pscustomobject]@{ Version = 1; Password = (New-SecretRecord $New); Recovery = $auth.Recovery })
    Write-Log 'password changed'
    return (New-Result $true 'הסיסמה שונתה.')
}

# Setting: "lock automatically N minutes after every unlock". Returns 0 when disabled.
function Get-DefaultAutoMinutes {
    try {
        $cfg = Read-Json $script:ConfigFile
        $d = Get-Prop $cfg 'DefaultAutoLock' $null
        if ($d -and [bool](Get-Prop $d 'Enabled' $false)) { return [int](Get-Prop $d 'Minutes' 0) }
    } catch { }
    return 0
}

# Saves both auto-lock settings at once (needs the password / recovery code):
#   DefaultEnabled/DefaultMinutes : lock N minutes after every unlock
#   DailyEnabled/DailyTime        : lock every day at HH:mm
function Invoke-SaveAutoLockSettings([string]$Password, [bool]$DefaultEnabled, [int]$DefaultMinutes, [bool]$DailyEnabled, [string]$DailyTime) {
    $ts = [timespan]::Zero
    if (-not [timespan]::TryParse($DailyTime, [ref]$ts) -or $ts.TotalHours -ge 24 -or $ts.TotalSeconds -lt 0) { return (New-Result $false 'שעה לא תקינה.') }
    if ($DefaultEnabled -and ($DefaultMinutes -lt 5 -or $DefaultMinutes -gt 1440)) { return (New-Result $false 'משך הנעילה חייב להיות בין 5 דקות ל-24 שעות.') }
    $a = Test-AuthSecret $Password $true
    if (-not $a.Ok) { return $a }
    Set-ConfigValue 'DefaultAutoLock' ([pscustomobject]@{ Enabled = $DefaultEnabled; Minutes = $DefaultMinutes })
    Set-ConfigValue 'DailyLock' ([pscustomobject]@{ Enabled = $DailyEnabled; Time = $ts.ToString('hh\:mm') })
    Write-Log "auto-lock settings: after-unlock=$DefaultEnabled/$DefaultMinutes daily=$DailyEnabled/$DailyTime"
    return (New-Result $true 'ההגדרות נשמרו.')
}

function Invoke-SaveSettings([string]$Password, [string[]]$Categories, [bool]$ShowTray, [bool]$Reminder, [bool]$Animations) {
    $a = Test-AuthSecret $Password $true
    if (-not $a.Ok) { return $a }
    $cats = @($Categories | Where-Object { $script:BlockCategories -contains $_ })
    Set-ConfigValue 'BlockCategories' $cats
    Set-ConfigValue 'ShowTray' $ShowTray
    Set-ConfigValue 'Reminder' $Reminder
    Set-ConfigValue 'Animations' $Animations
    Write-Log "settings: block=$($cats -join '+') tray=$ShowTray reminder=$Reminder animations=$Animations"
    try {
        $st = Get-StateInfo
        if ($st.Locked) { Set-WifiBlock }                       # re-apply with the new target set
        if ($ShowTray) { Start-ScheduledTask -TaskName 'WifiGate-Tray' -ErrorAction SilentlyContinue }
    } catch { Write-Log "settings apply error: $($_.Exception.Message)" }
    return (New-Result $true 'ההגדרות נשמרו.')
}

# Used by the Tick task while unlocked: has the auto-lock time passed, or the daily lock time?
function Test-LockDue {
    $st = Read-Json $script:StateFile
    if (-not $st -or $st.Mode -ne 'unlocked') { return $false }
    $now = Get-Date
    $v = [string](Get-Prop $st 'AutoLockAt' '')
    if ($v -and ([datetime]$v) -le $now) { return $true }
    $cfg = Read-Json $script:ConfigFile
    $dl = Get-Prop $cfg 'DailyLock' $null
    if ($dl -and [bool](Get-Prop $dl 'Enabled' $false)) {
        $ts = [timespan]::Zero
        if ([timespan]::TryParse([string](Get-Prop $dl 'Time' '23:00'), [ref]$ts)) {
            $due = $now.Date + $ts
            $changed = [datetime][string](Get-Prop $st 'ChangedAt' $now.ToString('o'))
            if ($now -ge $due -and $changed -lt $due) { return $true }
        }
    }
    return $false
}

# Accepts the password OR the recovery code. Opens Wi-Fi; does not uninstall.
function Invoke-Recovery([string]$Secret) {
    $auth = Read-Json $script:AuthFile
    if (-not $auth) { return (New-Result $false 'לא נמצאו נתוני אימות.') }
    $ok = (Test-SecretRecord $Secret $auth.Password) -or (Test-SecretRecord (ConvertTo-NormalCode $Secret) $auth.Recovery)
    if (-not $ok) { Write-Log 'recovery failed'; return (New-Result $false 'הסיסמה או קוד השחזור שגויים.') }
    Clear-WifiBlock
    Set-State 'unlocked'
    Write-Log 'recovery used'
    return (New-Result $true 'Wi-Fi נפתח.')
}

# ---------- tasks / uninstall ----------

function Register-WifiGateTasks {
    $ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scr = Join-Path $script:ProgDir 'Enforce.ps1'
    $base = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scr + '"'
    $princ = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $boot = New-ScheduledTaskAction -Execute $ps -Argument ($base + ' -Mode Boot')
    Register-ScheduledTask -TaskName 'WifiGate-Boot' -Action $boot -Principal $princ -Settings $set -Force `
        -Trigger @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)) `
        -Description 'WifiGate: re-locks Wi-Fi at startup and at logon.' | Out-Null

    $tick = New-ScheduledTaskAction -Execute $ps -Argument ($base + ' -Mode Tick')
    $tr = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName 'WifiGate-Tick' -Action $tick -Principal $princ -Settings $set -Force `
        -Trigger $tr -Description 'WifiGate: every minute, repairs the Wi-Fi block if it was removed while locked.' | Out-Null

    # Tray icon: runs elevated in the installing user's session at logon (no UAC prompt; it only shows state / locks / opens the window).
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $tray = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $script:ProgDir 'Tray.ps1') + '"')
        $tprinc = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
        $tset = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero)
        Register-ScheduledTask -TaskName 'WifiGate-Tray' -Action $tray -Principal $tprinc -Settings $tset -Force `
            -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $me) -Description 'WifiGate: tray icon.' | Out-Null
    } catch { Write-Log "tray task not registered: $($_.Exception.Message)" }
}

function Invoke-Uninstall {
    Stop-ScheduledTask -TaskName 'WifiGate-Tray' -ErrorAction SilentlyContinue
    foreach ($n in 'WifiGate-Tray', 'WifiGate-Boot', 'WifiGate-Tick', 'WifiGate-TrialFailsafe') {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
    try { Clear-WifiBlock } catch {
        Get-BlockRules | Remove-NetFirewallRule
    }
    $cfg = Read-Json $script:ConfigFile                      # shortcuts chosen at install time (names can be custom)
    foreach ($p in @(Get-Prop $cfg 'Shortcuts' @())) { Remove-Item -LiteralPath ([string]$p) -Force -ErrorAction SilentlyContinue }
    foreach ($p in @(Get-Prop $cfg 'Folders' @())) { Remove-Item -LiteralPath ([string]$p) -Recurse -Force -ErrorAction SilentlyContinue }
    $desk = [Environment]::GetFolderPath('Desktop')
    Get-ChildItem $desk -Filter 'WifiGate*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $desk ($script:DeskName + '.lnk')) -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) $script:StartFolder) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:ProgDir -Recurse -Force -ErrorAction SilentlyContinue
}
