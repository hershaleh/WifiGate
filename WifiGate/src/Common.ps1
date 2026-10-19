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
$script:RuleGroup    = 'WifiGate'
$script:Iterations   = 200000

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

function Set-State([string]$Mode) {
    Write-Json $script:StateFile ([pscustomobject]@{ Mode = $Mode; ChangedAt = (Get-Date).ToString('o') })
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

# ---------- firewall block ----------

function Get-BlockRules {
    return @(Get-NetFirewallRule -DisplayName 'WifiGate block*' -ErrorAction SilentlyContinue)
}

# Windows Firewall may store the interface filter either as the alias (name) or as the adapter's LUID number.
function Get-AdapterFilterIds([string]$Alias) {
    $ids = @($Alias)
    try {
        $a = Get-WifiAdapter
        $ids += [string]$a.Name
        foreach ($pr in $a.PSObject.Properties) {          # the LUID property is named NetLuid
            if ($pr.Name -eq 'NetLuid' -or $pr.Name -eq 'InterfaceLuid') { $ids += [string]$pr.Value }
        }
    } catch { }
    return @($ids)
}

# Returns $null when the block rules are correct, otherwise a text describing what is wrong.
function Get-BlockRulesProblem([string]$Alias) {
    $rules = @(Get-BlockRules)
    $ids = Get-AdapterFilterIds $Alias
    if ($rules.Count -ne 2) { return "נמצאו $($rules.Count) כללים, ציפיתי ל-2" }
    foreach ($r in $rules) {
        if ([string]$r.Enabled -ne 'True') { return "הכלל '$($r.DisplayName)' לא פעיל (Enabled=$($r.Enabled))" }
        if ([string]$r.Action -ne 'Block') { return "הכלל '$($r.DisplayName)' אינו חוסם (Action=$($r.Action))" }
        $f = $r | Get-NetFirewallInterfaceFilter
        if (-not $f) { return "לכלל '$($r.DisplayName)' אין סינון מתאם" }
        $al = @($f.InterfaceAlias | ForEach-Object { [string]$_ })
        if (@($al | Where-Object { $ids -contains $_ }).Count -eq 0) { return "סינון המתאם בכלל הוא [$($al -join ',')] ולא '$Alias'" }
    }
    $dirs = (@($rules | ForEach-Object { [string]$_.Direction }) | Sort-Object) -join ','
    if ($dirs -ne 'Inbound,Outbound') { return "כיווני הכללים: $dirs" }
    return $null
}

function Test-BlockRulesValid([string]$Alias) { return (-not (Get-BlockRulesProblem $Alias)) }

# Idempotent: makes sure the block is in place. Changes nothing if it already is.
function Set-WifiBlock {
    $a = Get-WifiAdapter
    $alias = $a.Name
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
    if (-not (Test-BlockRulesValid $alias)) {
        Get-BlockRules | Remove-NetFirewallRule
        foreach ($d in 'Outbound', 'Inbound') {
            New-NetFirewallRule -DisplayName ('WifiGate block ' + $d) -Group $script:RuleGroup `
                -Description 'WifiGate: blocks all traffic on the Wi-Fi interface until unlocked.' `
                -Direction $d -Action Block -InterfaceAlias $alias -Profile Any -Enabled True | Out-Null
        }
        Write-Log "firewall rules (re)created for alias of $($a.InterfaceGuid)"
    }
    if ($a.Status -ne 'Disabled') {
        Disable-NetAdapter -Name $alias -Confirm:$false
        Write-Log 'adapter disabled'
    }
}

function Clear-WifiBlock {
    Get-BlockRules | Remove-NetFirewallRule
    $a = Get-WifiAdapter
    if ($a.Status -eq 'Disabled') { Enable-NetAdapter -Name $a.Name -Confirm:$false }
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

function Invoke-Unlock([string]$Password) {
    $t = Read-Json $script:ThrottleFile
    if ($t -and $t.Until -and ([datetime]$t.Until) -gt (Get-Date)) {
        $s = [int]((([datetime]$t.Until) - (Get-Date)).TotalSeconds) + 1
        return (New-Result $false "יותר מדי ניסיונות. נסו שוב בעוד $s שניות.")
    }
    $auth = Read-Json $script:AuthFile
    if (-not $auth -or -not (Test-SecretRecord $Password $auth.Password)) {
        $f = 1; if ($t) { $f = [int]$t.Fails + 1 }
        $until = ''
        if ($f -ge 5) { $until = (Get-Date).AddSeconds([math]::Min(30 * ($f - 4), 600)).ToString('o') }
        Write-Json $script:ThrottleFile ([pscustomobject]@{ Fails = $f; Until = $until })
        Write-Log "unlock failed (#$f)"
        return (New-Result $false 'הסיסמה שגויה.')
    }
    Clear-WifiBlock                 # remove rules + enable adapter
    Set-State 'unlocked'
    Write-Json $script:ThrottleFile ([pscustomobject]@{ Fails = 0; Until = '' })
    Write-Log 'unlocked with password'
    return (New-Result $true 'Wi-Fi נפתח.')
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
}

function Invoke-Uninstall {
    foreach ($n in 'WifiGate-Boot', 'WifiGate-Tick', 'WifiGate-TrialFailsafe') {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
    try { Clear-WifiBlock } catch {
        Get-BlockRules | Remove-NetFirewallRule
    }
    $desk = [Environment]::GetFolderPath('Desktop')
    Get-ChildItem $desk -Filter 'WifiGate*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:ProgDir -Recurse -Force -ErrorAction SilentlyContinue
}
