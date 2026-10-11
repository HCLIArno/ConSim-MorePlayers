#requires -version 5.1
<#
    建筑模拟器 Construction Simulator —— 多人人数解锁（默认 8 人）
    一键安装 / 卸载脚本（单文件，Windows PowerShell 5.1 与 PowerShell 7 均可）

    安装：powershell -ExecutionPolicy Bypass -File install.ps1
    卸载：powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
    预演：powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun
          （只打印将要做什么，不写盘、不提权；确认无误后去掉 -DryRun 再真跑）

    设计原则：
      * 永不删除游戏原文件：所有要覆盖的内容先完整备份到带时间戳的目录
      * 优先自动定位游戏目录（Steam AppID 1273400 + 遍历所有 Steam 库）
      * 全中文输出，非技术用户照提示按回车即可
      * 卸载 = 把装进去的文件「移动」到备份目录，游戏立即回到原版
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,      # 卸载：移出插件文件，恢复原版
    [switch]$Force,          # 游戏运行中也继续
    [int]$MaxPlayers = 8,    # 目标人数上限（1-32）
    [string]$TargetDir,      # 手动指定游戏目录（自动定位失败时使用）
    [switch]$DryRun          # 预演：只打印将要做什么，不改动磁盘、不提权
)
# 注意：不要用 $gameDir / $resolvedDir 之类与参数大小写相同的局部变量名。
# PowerShell 变量名不区分大小写，二者是同一个变量，赋值会互相覆盖。

$ErrorActionPreference = 'Stop'

$AppId       = '1273400'
$GameFolder  = 'Construction Simulator'
$BakTag      = '_ConSimMorePlayers_备份'

# 安装会放进游戏根目录的条目；卸载就是把这些移走
$PayloadItems = @('BepInEx', 'dotnet', 'winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'changelog.txt')

# 预置的 Unity 基础库文件名。
# BepInEx 首次启动时本来要从 unity.bepinex.dev 下载这个文件（约 1.4 MB），
# 但只要 BepInEx\unity-libs\ 下已存在同名文件，它就会直接用本地的、完全跳过下载。
# 网速差的机器因此不必卡在这一步。文件名由 BepInEx 按 Unity 版本自动拼接，不能改名。
$UnityLibsZipName = '2020.3.49.zip'


# ----------------------------------------------------------------------
# -DryRun 预演支持
# ----------------------------------------------------------------------
if ($DryRun) { $script:DryTag = '[DryRun] ' } else { $script:DryTag = '' }

# 预演时把「将要执行」的写操作统统换成打印。$DryRun 为假时这些函数原样执行，
# 不带 -DryRun 的行为与以前完全一致。
function New-Item-Dry($Path, $ItemType = 'Directory') {
    if ($DryRun) {
        Write-Host "  $($script:DryTag)[模拟] 新建$ItemType：$Path" -ForegroundColor Cyan
    } else {
        New-Item -ItemType $ItemType -Path $Path -Force | Out-Null
    }
}
function Copy-Item-Dry($Path, $Destination, [switch]$Recurse, $Note) {
    if ($DryRun) {
        $extra = ''
        if ($Note) { $extra = "（$Note）" }
        Write-Host "  $($script:DryTag)[模拟] 复制：$Path" -ForegroundColor Cyan
        Write-Host "                            -> $Destination$extra" -ForegroundColor DarkGray
    } else {
        $params = @{ LiteralPath = $Path; Destination = $Destination; Force = $true }
        if ($Recurse) { $params.Recurse = $true }
        Copy-Item @params
    }
}
function Set-Content-Dry($Path, $Value, $Note) {
    if ($DryRun) {
        $extra = ''
        if ($Note) { $extra = "（$Note）" }
        Write-Host "  $($script:DryTag)[模拟] 写入配置：$Path$extra" -ForegroundColor Cyan
    } else {
        Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
    }
}
function Invoke-DryRunSummary {
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host '  [DryRun] 未做任何修改。实际执行请去掉 -DryRun' -ForegroundColor Yellow
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host ''
}

# 真正属于「原版游戏」的文件，用来确认找对了目录
$VanillaFiles = @('ConSim.exe', 'GameAssembly.dll', 'ConSim_Data')

function Write-Title($t) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
}
function Write-Ok($t)    { Write-Host "  [完成] $t" -ForegroundColor Green }
function Write-Note($t)  { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Write-Bad($t)   { Write-Host "  [错误] $t" -ForegroundColor Red }
function Write-Step($t)  { Write-Host "  ...    $t" -ForegroundColor Gray }
function Pause-Exit($code = 0) {
    Write-Host ''
    Read-Host '按回车键退出'
    exit $code
}

# 给 DryRun 清单用的可读大小（文件=字节数，目录=递归汇总）
function Format-Size($item) {
    if (-not $item.PSIsContainer) { return "$($item.Length) 字节" }
    $sum = 0
    $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) { $sum += $f.Length }
    return "$($files.Count) 个文件，共 $sum 字节"
}

# ======================================================================
# 权限与可写性
# ======================================================================
$script:IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 很多人的 Steam 装在非系统盘（如 D:\Software\steam），那种情况根本不需要提权。
# 所以先实测能不能写，不能写再提权，避免无谓地弹 UAC。
function Test-CanWrite([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    # 预演时绝不产生任何文件，连探针文件也不写
    if ($DryRun) { return $true }
    $probe = Join-Path $dir ('.write_probe_' + [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Invoke-Elevated {
    Write-Title '需要管理员权限'
    Write-Note '这个位置的游戏目录当前账户不能写，正在弹出管理员授权窗口，请点「是」。'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-MaxPlayers', $MaxPlayers)
    if ($TargetDir) { $argList += @('-TargetDir', "`"$resolvedDir`"") }
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($Force)     { $argList += '-Force' }
    # -DryRun 不会走到这里（DryRun 下不提权），这里保持不带该参数
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Bad '提权被取消。请右键本脚本 →「以管理员身份运行」。'
        Read-Host '按回车键退出'
    }
    exit
}

# ======================================================================
# 定位游戏
# ======================================================================
function Get-SteamRoot {
    $cands = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam',
                     'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                     'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.SteamPath)   { $cands += $v.SteamPath }
            if ($v.InstallPath) { $cands += $v.InstallPath }
        } catch { }
    }
    foreach ($c in $cands) {
        $p = $c -replace '/', '\'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-SteamLibraries([string]$steamRoot) {
    $libs = @()
    if ($steamRoot) { $libs += $steamRoot }
    if ($steamRoot) {
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in (Get-Content -LiteralPath $vdf -Encoding UTF8)) {
                $m = [regex]::Match($line, '"path"\s+"([^"]+)"')
                if ($m.Success) {
                    # vdf 里是转义过的 \\ ，还原成单反斜杠
                    $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                }
            }
        }
    }
    return ($libs | Where-Object { $_ } | Select-Object -Unique)
}

function Test-IsGameDir([string]$dir) {
    if (-not $dir) { return $false }
    foreach ($f in $VanillaFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $f))) { return $false }
    }
    return $true
}

function Find-GameDir {
    $steamRoot = Get-SteamRoot
    $libs = Get-SteamLibraries $steamRoot

    # 1) 优先：库里 appmanifest_1273400.acf + ConSim.exe 同时存在
    foreach ($lib in $libs) {
        $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        $dir = Join-Path $lib "steamapps\common\$GameFolder"
        if ((Test-Path -LiteralPath $acf) -and (Test-IsGameDir $dir)) { return $dir }
    }
    # 2) 退一步：只看游戏目录
    foreach ($lib in $libs) {
        $dir = Join-Path $lib "steamapps\common\$GameFolder"
        if (Test-IsGameDir $dir) { return $dir }
    }
    # 3) 兜底：常见盘符
    foreach ($drv in @('C:', 'D:', 'E:', 'F:', 'G:', 'H:')) {
        foreach ($sub in @("$drv\SteamLibrary", "$drv\Steam", "$drv\Games\Steam",
                           "$drv\Software\steam", "$drv\Program Files (x86)\Steam")) {
            $dir = Join-Path $sub "steamapps\common\$GameFolder"
            if (Test-IsGameDir $dir) { return $dir }
        }
    }
    return $null
}

# ======================================================================
# 开始
# ======================================================================
if ($Uninstall) {
    Write-Title '建筑模拟器 多人人数解锁 —— 卸载（恢复原版）'
} else {
    Write-Title '建筑模拟器 多人人数解锁 —— 安装'
}
if ($DryRun) {
    Write-Host '  [DryRun] 预演模式：只打印将要做什么，不会创建/复制/移动/删除任何文件，也不会弹出 UAC。' -ForegroundColor Magenta
    Write-Host '  [DryRun] 看完无误后，去掉 -DryRun 再正式运行即可。' -ForegroundColor Magenta
}

Write-Step '正在定位游戏安装目录…'
$resolvedDir = $null
if ($TargetDir) {
    if (Test-Path -LiteralPath $TargetDir) {
        $resolvedDir = (Resolve-Path -LiteralPath $TargetDir).Path
        if (Test-IsGameDir $resolvedDir) {
            Write-Ok "使用手动指定的游戏目录：$resolvedDir"
        } else {
            Write-Note '手动指定的目录里看不到 ConSim.exe / GameAssembly.dll，仍按该目录继续。'
            Write-Ok "使用手动指定的游戏目录：$resolvedDir"
        }
    } else {
        Write-Note "手动指定的目录不存在：$TargetDir，改为自动定位。"
        $resolvedDir = Find-GameDir
    }
} else {
    $resolvedDir = Find-GameDir
}
if (-not $resolvedDir) {
    Write-Bad '没有找到《建筑模拟器》的安装目录。'
    Write-Host '       请先在 Steam 里确认游戏已安装，再重新运行本脚本。' -ForegroundColor Yellow
    Pause-Exit 1
}
Write-Ok "游戏目录：$resolvedDir"

# 原版标志校验（预演也要完整做一遍，好让用户确认找对了目录）
$vanillaFound = @()
$vanillaMissing = @()
foreach ($vf in $VanillaFiles) {
    if (Test-Path -LiteralPath (Join-Path $resolvedDir $vf)) { $vanillaFound += $vf } else { $vanillaMissing += $vf }
}
if ($vanillaMissing.Count -eq 0) {
    Write-Ok "原版标志校验通过：$($vanillaFound -join '、')"
} else {
    Write-Note "该目录里缺少原版标志：$($vanillaMissing -join '、')（已找到：$($vanillaFound -join '、')）"
}

# 定位到了再判断要不要提权（Steam 装在非系统盘时通常不需要）
# 预演模式绝不提权，也绝不写探针文件（Test-CanWrite 在 -DryRun 下直接返回可写）
if (-not (Test-CanWrite $resolvedDir)) {
    if ($DryRun) {
        Write-Note '该目录当前账户不可写；正式安装时会弹出管理员授权（UAC）。预演模式不提权，继续。'
    } else {
        Invoke-Elevated
    }
}

# ======================================================================
# 卸载分支
# ======================================================================
if ($Uninstall) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $moveTo = Join-Path $resolvedDir "$BakTag\卸载-$stamp"

    $found = @()
    foreach ($item in $PayloadItems) {
        if (Test-Path -LiteralPath (Join-Path $resolvedDir $item)) { $found += $item }
    }

    if ($found.Count -eq 0) {
        Write-Note '没有发现本插件装进去的文件，游戏已经是原版。'
        if ($DryRun) { Invoke-DryRunSummary; exit 0 }
        Pause-Exit 0
    }

    if ($DryRun) {
        Write-Title '以下是将要执行的操作（未执行）'
        Write-Host "  卸载目标目录：$resolvedDir" -ForegroundColor White
        Write-Host "  将会新建目录：$moveTo" -ForegroundColor Gray
        Write-Host "  将会移出（移动、不删除）以下 $($found.Count) 项：" -ForegroundColor White
        foreach ($item in $found) {
            $src = Join-Path $resolvedDir $item
            $gi  = Get-Item -LiteralPath $src -Force
            $kind = if ($gi.PSIsContainer) { '目录' } else { '文件' }
            Write-Host ("    - {0,-24} {1}，{2}" -f $item, $kind, (Format-Size $gi)) -ForegroundColor Gray
            Write-Host ("        从：{0}" -f $src) -ForegroundColor DarkGray
            Write-Host ("        到：{0}" -f (Join-Path $moveTo $item)) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host "  移出后游戏根目录只剩原版文件：$($VanillaFiles -join '、')" -ForegroundColor White
        Write-Host "  移出的文件不会删除，完整保留在备份目录里。" -ForegroundColor Gray
        Invoke-DryRunSummary
        exit 0
    }

    New-Item-Dry -Path $moveTo -ItemType Directory
    Write-Step "正在把文件移出（不是删除）到：$moveTo"
    foreach ($item in $found) {
        Move-Item -LiteralPath (Join-Path $resolvedDir $item) `
                  -Destination (Join-Path $moveTo $item) -Force
        Write-Ok "已移出 $item"
    }

    Write-Title '卸载完成'
    Write-Host "  游戏已恢复原版，共移出 $($found.Count) 项。" -ForegroundColor White
    Write-Host '  文件没有删除，完整保留在：' -ForegroundColor Gray
    Write-Host "    $moveTo" -ForegroundColor Gray
    Write-Host '  想重新安装，再运行一次「一键安装.bat」即可。' -ForegroundColor Gray
    Pause-Exit 0
}

# ======================================================================
# 安装分支
# ======================================================================
if ($MaxPlayers -lt 1 -or $MaxPlayers -gt 32) {
    Write-Note "-MaxPlayers 超出范围（1-32），已改用默认值 8。"
    $MaxPlayers = 8
}

# ---- DryRun：把整个安装流程要做的写操作列出来，然后退出，绝不落盘 ----
if ($DryRun) {
    $dryStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dryBakDir = Join-Path $resolvedDir "$BakTag\安装前-$dryStamp"

    $dryZip = Join-Path $PSScriptRoot '..\payload\BepInEx6-win-x64.zip'
    if (-not (Test-Path -LiteralPath $dryZip)) { $dryZip = Join-Path $PSScriptRoot 'BepInEx6-win-x64.zip' }
    $dryDll = Join-Path $PSScriptRoot '..\payload\ConSimMorePlayers.dll'
    if (-not (Test-Path -LiteralPath $dryDll)) { $dryDll = Join-Path $PSScriptRoot 'ConSimMorePlayers.dll' }
    $dryUl  = Join-Path $PSScriptRoot "..\payload\unity-libs\$UnityLibsZipName"
    if (-not (Test-Path -LiteralPath $dryUl)) { $dryUl = Join-Path $PSScriptRoot "unity-libs\$UnityLibsZipName" }

    $dryToBackup = @()
    foreach ($item in $PayloadItems) {
        if (Test-Path -LiteralPath (Join-Path $resolvedDir $item)) { $dryToBackup += $item }
    }
    $dryToRemove = @()
    foreach ($item in $PayloadItems) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolvedDir $item))) { $dryToRemove += $item }
    }

    $dryCfg    = Join-Path $resolvedDir 'BepInEx\config\com.dsh.consim.moreplayers.cfg'
    $dryCfgNew = -not (Test-Path -LiteralPath $dryCfg)

    Write-Title '以下是将要执行的操作（未执行）'

    Write-Host '  【目录与校验】' -ForegroundColor White
    Write-Host "    目标游戏目录   : $resolvedDir" -ForegroundColor Gray
    Write-Host "    原版标志       : $(if ($vanillaMissing.Count -eq 0) { "已全部找到（$($vanillaFound -join '、')）" } else { "缺少 $($vanillaMissing -join '、')" })" -ForegroundColor Gray
    Write-Host "    目录可写       : 未检测（预演模式不写探针文件；正式安装会实测，不可写才弹 UAC）" -ForegroundColor Gray
    Write-Host "    目标人数上限   : $MaxPlayers" -ForegroundColor Gray
    Write-Host "    运行库压缩包   : $dryZip $(if (Test-Path -LiteralPath $dryZip) { '（存在）' } else { '（缺失！正式安装会报错）' })" -ForegroundColor Gray
    Write-Host "    插件 DLL       : $dryDll $(if (Test-Path -LiteralPath $dryDll) { '（存在）' } else { '（缺失！正式安装会报错）' })" -ForegroundColor Gray

    Write-Host ''
    Write-Host '  【第 1 步 / 共 4 步：备份】' -ForegroundColor White
    if ($dryToBackup.Count -gt 0) {
        Write-Host "    将会新建备份目录：$dryBakDir" -ForegroundColor Gray
        Write-Host "    将会复制以下 $($dryToBackup.Count) 项到备份目录（只读，不改动原件）：" -ForegroundColor Gray
        foreach ($item in $dryToBackup) {
            $src = Join-Path $resolvedDir $item
            $gi  = Get-Item -LiteralPath $src -Force
            Write-Host ("      - {0,-24} {1}" -f $item, (Format-Size $gi)) -ForegroundColor DarkGray
        }
    } else {
        Write-Host '    目录很干净，没有需要备份的旧文件（不会新建备份目录）。' -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '  【第 2 步 / 共 4 步：安装 BepInEx 6 运行库】' -ForegroundColor White
    Write-Host "    将会解压 $dryZip" -ForegroundColor Gray
    Write-Host '    到临时目录（正式安装时创建，装完自动清理）：%TEMP%\ConSimMorePlayers_<随机>' -ForegroundColor Gray
    Write-Host "    再逐项复制到 $resolvedDir ：" -ForegroundColor Gray
    if (Test-Path -LiteralPath $dryZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zipNames = @()
        try {
            $za = [System.IO.Compression.ZipFile]::OpenRead($dryZip)
            try {
                $zipNames = @($za.Entries | ForEach-Object { ($_.FullName -split '/')[0] } | Where-Object { $_ } | Select-Object -Unique)
            } finally { $za.Dispose() }
        } catch {
            Write-Host '      （无法读取压缩包内容，正式安装时才会知道具体条目）' -ForegroundColor DarkGray
        }
        foreach ($n in $zipNames) {
            $exist = Test-Path -LiteralPath (Join-Path $resolvedDir $n)
            $mark  = if ($exist) { '（已存在，将被覆盖；已在上一步备份）' } else { '（新增）' }
            Write-Host ("      - {0,-24} {1}" -f $n, $mark) -ForegroundColor DarkGray
        }
    } else {
        Write-Host '      - 无法列出：压缩包缺失，正式安装会在此处报错退出。' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  【第 3 步 / 共 4 步：预置 Unity 基础库（免下载）】' -ForegroundColor White
    if (Test-Path -LiteralPath $dryUl) {
        Write-Host "    将会复制 $dryUl" -ForegroundColor Gray
        Write-Host "            到 $(Join-Path $resolvedDir "BepInEx\unity-libs\$UnityLibsZipName")" -ForegroundColor Gray
        Write-Host '    作用：首次启动时 BepInEx 直接用这个文件，跳过联网下载（约 1.4 MB）。' -ForegroundColor DarkGray
    } else {
        Write-Host "    未找到预置的 $UnityLibsZipName（正式安装时会改为提示联网下载）。" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  【第 4 步 / 共 4 步：放入插件并写入人数】' -ForegroundColor White
    Write-Host "    将会新建目录：$(Join-Path $resolvedDir 'BepInEx\plugins')" -ForegroundColor Gray
    Write-Host "    将会复制 $dryDll" -ForegroundColor Gray
    Write-Host "            到 $(Join-Path $resolvedDir 'BepInEx\plugins\ConSimMorePlayers.dll')" -ForegroundColor Gray
    Write-Host "    将会新建目录：$(Join-Path $resolvedDir 'BepInEx\config')" -ForegroundColor Gray
    if ($dryCfgNew) {
        Write-Host "    将会新建配置文件：$dryCfg" -ForegroundColor Gray
        Write-Host '    内容如下：' -ForegroundColor Gray
        Write-Host '      --- 8< ---' -ForegroundColor DarkGray
        foreach ($line in @('## 由一键安装脚本生成', '[General]', '',
                            '## 房间最大玩家数（原版为 4，上限 32）', "MaxPlayers = $MaxPlayers", '',
                            '## 输出详细日志，排查问题时可改为 true', 'VerboseLog = true', '',
                            '## 绕过「必须先通关开局战役」的限制。默认 false，保持游戏原版行为', 'UnlockMultiplayer = false')) {
            Write-Host "      $line" -ForegroundColor DarkGray
        }
        Write-Host '      --- 8< ---' -ForegroundColor DarkGray
    } else {
        $cfgText = Get-Content -LiteralPath $dryCfg -Raw -Encoding UTF8
        if ($cfgText -match '(?m)^MaxPlayers\s*=') {
            $oldLine = ([regex]::Match($cfgText, '(?m)^MaxPlayers\s*=.*$')).Value
            Write-Host "    配置文件已存在：$dryCfg" -ForegroundColor Gray
            Write-Host "    将会只改 MaxPlayers 一行（其余设置原样保留）：" -ForegroundColor Gray
            Write-Host "      改前：$oldLine" -ForegroundColor DarkGray
            Write-Host "      改后：MaxPlayers = $MaxPlayers" -ForegroundColor DarkGray
        } else {
            Write-Host "    配置文件已存在但缺少 MaxPlayers 行：$dryCfg" -ForegroundColor Gray
            Write-Host "    将会在末尾追加一行：MaxPlayers = $MaxPlayers" -ForegroundColor DarkGray
        }
        Write-Host '    下列既有设置将会保留：' -ForegroundColor Gray
        foreach ($m in [regex]::Matches($cfgText, '(?m)^([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*)$')) {
            if ($m.Groups[1].Value -ne 'MaxPlayers') {
                Write-Host ("      {0} = {1}" -f $m.Groups[1].Value, $m.Groups[2].Value) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ''
    Write-Host "    将会提示：把游戏里「最大玩家数」调到 $MaxPlayers" -ForegroundColor Gray

    Invoke-DryRunSummary
    exit 0
}

# 游戏在运行？
$running = @(Get-Process -Name 'ConSim' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if ($Force) {
        Write-Note '游戏正在运行（已指定 -Force），继续安装。装完请重启游戏。'
    } else {
        Write-Note '检测到游戏正在运行。'
        Write-Host '       请先完全退出游戏，然后按回车继续。' -ForegroundColor Yellow
        Read-Host '       退出游戏后按回车'
        if (@(Get-Process -Name 'ConSim' -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Bad '游戏仍在运行，请退出后重新运行本脚本。'
            Pause-Exit 1
        }
    }
}

# ----------------------------------------------------------------------
# 1) 备份
# ----------------------------------------------------------------------
Write-Title '第 1 步 / 共 4 步：备份现有文件'

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakDir = Join-Path $resolvedDir "$BakTag\安装前-$stamp"

$toBackup = @()
foreach ($item in $PayloadItems) {
    if (Test-Path -LiteralPath (Join-Path $resolvedDir $item)) { $toBackup += $item }
}

if ($toBackup.Count -gt 0) {
    New-Item-Dry -Path $bakDir -ItemType Directory
    foreach ($item in $toBackup) {
        $src = Join-Path $resolvedDir $item
        $dst = Join-Path $bakDir $item
        if ((Get-Item -LiteralPath $src).PSIsContainer) {
            Write-Step "备份目录 $item（可能较大，请稍等）…"
            Copy-Item-Dry -Path $src -Destination $dst -Recurse
        } else {
            Copy-Item-Dry -Path $src -Destination $dst
        }
        Write-Ok "已备份 $item"
    }
    Write-Host "        备份位置：$bakDir" -ForegroundColor Gray
} else {
    Write-Ok '目录很干净，没有需要备份的旧文件。'
}

# ----------------------------------------------------------------------
# 2) 释放 BepInEx 运行库
# ----------------------------------------------------------------------
Write-Title '第 2 步 / 共 4 步：安装 BepInEx 6 运行库'

$zip = Join-Path $PSScriptRoot '..\payload\BepInEx6-win-x64.zip'
if (-not (Test-Path -LiteralPath $zip)) { $zip = Join-Path $PSScriptRoot 'BepInEx6-win-x64.zip' }
if (-not (Test-Path -LiteralPath $zip)) {
    Write-Bad '找不到运行库压缩包 BepInEx6-win-x64.zip。'
    Write-Host '       请解压整个安装包后再运行，不要只把脚本单独拿出来。' -ForegroundColor Yellow
    Pause-Exit 1
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

# 先解到临时目录，再逐项覆盖复制。
# 原因：.NET Framework 的 ExtractToDirectory 遇到已存在的文件会直接抛异常，
#       已经装过 BepInEx 的机器重装会失败。
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ConSimMorePlayers_" + [Guid]::NewGuid().ToString('N'))
New-Item-Dry -Path $tmp -ItemType Directory

if ($DryRun) {
    Write-Step '正在解压运行库（约 160 MB，需要十几秒）…'
    Write-Host "  $($script:DryTag)[模拟] 解压 $zip -> $tmp" -ForegroundColor Cyan
    Write-Step '正在复制到游戏目录…'
    Write-Host "  $($script:DryTag)[模拟] 复制 $tmp 下全部条目 -> $resolvedDir" -ForegroundColor Cyan
    Write-Ok 'BepInEx 运行库已就位。（预演，未实际写入）'
} else {
    try {
        Write-Step '正在解压运行库（约 160 MB，需要十几秒）…'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)

        Write-Step '正在复制到游戏目录…'
        foreach ($name in (Get-ChildItem -LiteralPath $tmp -Force | Select-Object -ExpandProperty Name)) {
            Copy-Item -LiteralPath (Join-Path $tmp $name) `
                      -Destination (Join-Path $resolvedDir $name) -Recurse -Force
        }
        Write-Ok 'BepInEx 运行库已就位。'
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------
# 3) 预置 Unity 基础库，免去首次启动的联网下载
# ----------------------------------------------------------------------
Write-Title '第 3 步 / 共 4 步：预置 Unity 基础库（免下载）'

$ulZip = Join-Path $PSScriptRoot "..\payload\unity-libs\$UnityLibsZipName"
if (-not (Test-Path -LiteralPath $ulZip)) { $ulZip = Join-Path $PSScriptRoot "unity-libs\$UnityLibsZipName" }

$ulDir = Join-Path $resolvedDir 'BepInEx\unity-libs'
if (Test-Path -LiteralPath $ulZip) {
    New-Item-Dry -Path $ulDir -ItemType Directory
    Copy-Item-Dry -Path $ulZip -Destination (Join-Path $ulDir $UnityLibsZipName) -Note '首次启动免联网下载'
    Write-Ok "已预置 Unity 基础库 $UnityLibsZipName"
    Write-Host '        首次启动时 BepInEx 会直接用它，不再联网下载。' -ForegroundColor Gray
} else {
    Write-Note "未找到预置的 $UnityLibsZipName，首次启动时 BepInEx 会自行联网下载（约 1.4 MB）。"
}

# ----------------------------------------------------------------------
# 4) 放入插件并写入人数
# ----------------------------------------------------------------------
Write-Title '第 4 步 / 共 4 步：安装人数解锁插件'

$dll = Join-Path $PSScriptRoot '..\payload\ConSimMorePlayers.dll'
if (-not (Test-Path -LiteralPath $dll)) { $dll = Join-Path $PSScriptRoot 'ConSimMorePlayers.dll' }
if (-not (Test-Path -LiteralPath $dll)) {
    Write-Bad '找不到插件文件 ConSimMorePlayers.dll。'
    Pause-Exit 1
}

$plugDir = Join-Path $resolvedDir 'BepInEx\plugins'
New-Item-Dry -Path $plugDir -ItemType Directory
Copy-Item-Dry -Path $dll -Destination (Join-Path $plugDir 'ConSimMorePlayers.dll')
Write-Ok '插件已放入 BepInEx\plugins\'

# 人数写进配置文件（若已存在则只改 MaxPlayers 那一行，保留其他设置）
$cfgDir = Join-Path $resolvedDir 'BepInEx\config'
$cfg    = Join-Path $cfgDir 'com.dsh.consim.moreplayers.cfg'
New-Item-Dry -Path $cfgDir -ItemType Directory

if (Test-Path -LiteralPath $cfg) {
    $text = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
    if ($text -match '(?m)^MaxPlayers\s*=') {
        $text = [regex]::Replace($text, '(?m)^MaxPlayers\s*=.*$', "MaxPlayers = $MaxPlayers")
    } else {
        $text = $text.TrimEnd() + "`r`nMaxPlayers = $MaxPlayers`r`n"
    }
    Set-Content-Dry -Path $cfg -Value $text -Note "只改 MaxPlayers 一行"
    Write-Ok "已把配置文件里的人数改为 $MaxPlayers（其他设置保持不变）"
} else {
    $content = @"
## 由一键安装脚本生成
[General]

## 房间最大玩家数（原版为 4，上限 32）
MaxPlayers = $MaxPlayers

## 输出详细日志，排查问题时可改为 true
VerboseLog = true

## 绕过「必须先通关开局战役」的限制。默认 false，保持游戏原版行为
UnlockMultiplayer = false
"@
    Set-Content-Dry -Path $cfg -Value $content -Note '新建文件'
    Write-Ok "已生成配置文件，人数 = $MaxPlayers"
}

# ----------------------------------------------------------------------
# 完成
# ----------------------------------------------------------------------
Write-Title '安装完成'

Write-Host ''
Write-Host '  接下来怎么用：' -ForegroundColor White
Write-Host '    1. 从 Steam 正常启动《建筑模拟器》' -ForegroundColor Gray
Write-Host '    2. 会先弹出一个黑色日志小窗口，属于正常现象，可以最小化' -ForegroundColor Gray
Write-Host "    3. 进入「创建多人游玩」，把「最大玩家数」调到 $MaxPlayers" -ForegroundColor Gray
Write-Host '    4. 建房后朋友就能在多人游戏大厅里看到你的房间了' -ForegroundColor Gray
Write-Host ''
Write-Host '  ★ 重要：所有一起玩的人都要装这个，否则他们的游戏还是按 4 人过滤，' -ForegroundColor Yellow
Write-Host '    在大厅里看不到你的房间。把整个安装包发给他们，各自跑一遍即可。' -ForegroundColor Yellow
Write-Host ''
Write-Host '  怎么确认装好了（可选）：' -ForegroundColor White
Write-Host "    $resolvedDir\BepInEx\LogOutput.log" -ForegroundColor Gray
Write-Host '    打开后能看到「ConSim More Players 已加载，目标房间人数 = ' -ForegroundColor Gray
Write-Host ''
Write-Host '  想恢复原版：' -ForegroundColor White
Write-Host '    运行「一键卸载.bat」，装进去的文件会被移到备份目录，不会删除。' -ForegroundColor Gray
if ($toBackup.Count -gt 0) {
    Write-Host "    安装前的备份：$bakDir" -ForegroundColor Gray
}
Write-Host ''
if ($DryRun) {
    Invoke-DryRunSummary
    exit 0
}
Pause-Exit 0
