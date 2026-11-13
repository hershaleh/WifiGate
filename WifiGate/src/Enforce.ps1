# WifiGate - Enforce.ps1  (runs as SYSTEM from scheduled tasks)
#   -Mode Boot : at startup / logon -> always lock.
#   -Mode Tick : every minute -> if not explicitly "unlocked", make sure the block is in place.
param([ValidateSet('Boot', 'Tick')][string]$Mode = 'Tick')

. (Join-Path $PSScriptRoot 'Common.ps1')

try {
    if ($Mode -eq 'Boot') {
        Invoke-Lock
        exit 0
    }
    # Missing or unreadable state counts as locked (fail closed).
    $st = $null
    try { $st = Read-Json $script:StateFile } catch { Write-Log "state unreadable: $_" }
    if (-not $st -or $st.Mode -ne 'unlocked') { Set-WifiBlock }
    elseif (Test-LockDue) { Invoke-Lock; Write-Log 'auto-lock (timer or daily schedule)' }
    else { Update-LastSeen }
    exit 0
} catch {
    Write-Log "enforce error ($Mode): $($_.Exception.Message)"
    exit 1
}
