# Console.ps1 : terminal that shows only meaningless filler text. Keys (not displayed):
#   1 = open window (password)   2 = lock   3 = checks window   4 = recovery window   Q / Esc = exit
param([string]$Choice = '')

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-IsAdmin)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Start-Window([string]$Script) {
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $PSScriptRoot $Script) + '"'))
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Neutral filler vocabulary (English + Chinese). Nothing here relates to the tool's purpose.
$script:En = @('vellum', 'tangent', 'halcyon', 'sable', 'quorum', 'ember', 'marrow', 'lattice', 'orbit', 'cobalt', 'fathom', 'gossamer', 'nimbus', 'pylon', 'russet', 'umber', 'zephyr', 'obsidian', 'tessera', 'argent', 'bramble', 'cinder', 'dovetail', 'eddy', 'flint')
$script:Zh = @('缓存', '节点', '同步', '光谱', '回声', '琥珀', '星图', '溪流', '算法', '矩阵', '云端', '棱镜', '潮汐', '回路', '纹理', '信标', '坐标', '渐变', '脉冲', '轨迹')

function New-FillerLine {
    $n = Get-Random -Minimum 3 -Maximum 8
    $parts = @()
    for ($i = 0; $i -lt $n; $i++) {
        switch (Get-Random -Maximum 5) {
            0 { $parts += ($script:Zh | Get-Random) }
            1 { $parts += ($script:Zh | Get-Random) }
            2 { $parts += ('0x{0:x4}' -f (Get-Random -Maximum 65535)) }
            default { $parts += ($script:En | Get-Random) }
        }
    }
    $stamp = (Get-Date).AddSeconds(-(Get-Random -Maximum 600)).ToString('HH:mm:ss')
    return ('  {0}  {1}' -f $stamp, ($parts -join ' '))
}

function Show-Filler([int]$Lines) {
    for ($i = 0; $i -lt $Lines; $i++) { Write-Host (New-FillerLine); Start-Sleep -Milliseconds (Get-Random -Minimum 15 -Maximum 70) }
}

try { $Host.UI.RawUI.WindowTitle = 'Terminal'; $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'DarkGray' } catch { }
Clear-Host
Show-Filler (Get-Random -Minimum 9 -Maximum 15)

$done = $false
while (-not $done) {
    if ($Choice) { $key = $Choice.Substring(0, 1); $Choice = '' }
    else {
        $k = [Console]::ReadKey($true)               # not echoed
        if ($k.Key -eq 'Escape') { $key = 'Q' } else { $key = [string]$k.KeyChar }
    }
    switch ($key.ToUpper()) {
        '1' { Start-Window 'Unlock-UI.ps1'; $done = $true }
        '2' { try { Invoke-Lock } catch { Write-Log "console lock error: $($_.Exception.Message)" }; $done = $true }
        '3' { Start-Window 'Tests.ps1'; $done = $true }
        '4' { Start-Window 'Recovery.ps1'; $done = $true }
        'Q' { $done = $true }
        default { Show-Filler 1 }                    # any other key just prints another meaningless line
    }
}
Show-Filler 2
Start-Sleep -Milliseconds 500
