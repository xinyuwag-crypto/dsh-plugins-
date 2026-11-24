#requires -Version 5.1
<#
.SYNOPSIS
    本机磁盘自动清理：系统临时文件、Windows 更新缓存、下载目录安装包、
    应用/浏览器缓存、重复文件、回收站与缩略图缓存。

.DESCRIPTION
    默认行为（安全优先）：
      * 临时文件、缓存、回收站、缩略图缓存 -> 直接删除（可再生，无保留价值）
      * 下载目录安装包、重复文件          -> 移入 quarantine 隔离区，保留 7 天可恢复
      * 非管理员运行时自动跳过需要提权的目标（Windows\Temp、更新缓存），只做统计

    每次运行都会写入 logs\cleanup-*.log、reports\latest.md、reports\latest.json。

.PARAMETER DryRun
    只扫描统计，不删除、不移动任何文件。

.PARAMETER SkipElevated
    跳过所有需要管理员权限的目标（不产生"需管理员"提示中的统计）。

.PARAMETER QuarantineAll
    连临时文件/缓存也移入隔离区而不是直接删除（更保守，但占用空间更多）。

.EXAMPLE
    pwsh -File cleanup.ps1 -DryRun
    pwsh -File cleanup.ps1
    pwsh -File cleanup.ps1 -QuarantineDays 14 -InstallerAgeDays 60
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipElevated,
    [switch]$QuarantineAll,
    [int]$QuarantineDays    = 7,
    [int]$InstallerAgeDays  = 30,
    [int]$DuplicateMinMB    = 10,
    [switch]$Quiet,
    # 只执行指定类别。默认仅安全三项：Temp / Update / Cache
    # 其余类别（Recycle / Installers / Duplicates）必须显式指定，或用 -All 开启全部
    [ValidateSet('Temp', 'Update', 'Cache', 'Recycle', 'Installers', 'Duplicates')]
    [string[]]$Only,
    # 显式开启全部六类（含重复文件扫描，风险最高）
    [switch]$All,
    # 日志/报告/隔离区根目录，默认与脚本同级（插件调用时传入数据目录）
    [string]$DataDir,
    # 逗号分隔的类别列表，等价于 -Only（便于从其他进程传参）
    [string]$Categories,
    # 始终把本次运行的结构化摘要写到该路径，供调用方读取
    [string]$SummaryPath
)

# 调用方是否显式限定了类别（用于区分正式运行与临时试跑）
$script:ExplicitCategories = [bool]$Categories -or [bool]$Only -or [bool]$All

if ($Categories) {
    $Only = @($Categories -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($All) { $Only = $null }
# 未指定类别时只跑安全三项，避免误伤回收站、下载目录安装包与文档类重复文件
if (-not $Only) { $Only = @('Temp', 'Update', 'Cache') }

# 任何情况下都不清理的文件类型
$script:ProtectedExtensions = @('.py', '.ipynb', '.md', '.ipr')
function Test-ProtectedPath {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    return ($ext -and ($script:ProtectedExtensions -contains $ext.ToLowerInvariant()))
}

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------- 基础设置
$ScriptDir     = Split-Path -Parent $PSCommandPath
$DataRoot      = if ($DataDir) { $DataDir } else { $ScriptDir }
$LogDir        = Join-Path $DataRoot 'logs'
$ReportDir     = Join-Path $DataRoot 'reports'
$QuarantineDir = Join-Path $DataRoot 'quarantine'
foreach ($d in @($LogDir, $ReportDir, $QuarantineDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$Started = Get-Date
$LogFile = Join-Path $LogDir "cleanup-$Stamp.log"

$script:LogLines     = [System.Collections.Generic.List[string]]::new()
$script:Stats        = @{}          # category -> @{ Count; Bytes }
$script:QuarantineItems = [System.Collections.Generic.List[object]]::new()
$script:Skipped      = [System.Collections.Generic.List[object]]::new()
$script:Errors       = [System.Collections.Generic.List[string]]::new()
$script:PurgedBatches = [System.Collections.Generic.List[object]]::new()
$script:BatchDir     = Join-Path $QuarantineDir $Stamp
$script:Seq          = 0

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Windows 更新服务状态（提权清理更新缓存后需要恢复）
$script:WUWasRunning = $false

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $script:LogLines.Add($line)
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    if (-not $Quiet) {
        $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Gray'} }
        Write-Host $line -ForegroundColor $color
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function Add-Stat {
    param([string]$Category, [double]$Bytes, [int]$Count = 1)
    if (-not $script:Stats.ContainsKey($Category)) {
        $script:Stats[$Category] = @{ Count = 0; Bytes = [double]0 }
    }
    $script:Stats[$Category].Count += $Count
    $script:Stats[$Category].Bytes += $Bytes
}

function Add-Skipped {
    param([string]$Reason, [string]$Path, [string]$Size = '')
    $script:Skipped.Add([pscustomobject]@{ Reason = $Reason; Path = $Path; Size = $Size })
}

function Get-SafeFileSize {
    param([string]$Path)
    try { return [double](Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length } catch { return 0 }
}

# 直接删除单个文件（可再生数据）
function Remove-RegenerableFile {
    param([string]$Path, [string]$Category)
    if (Test-ProtectedPath $Path) {
        Add-Skipped '受保护的文件类型（.py/.ipynb/.md/.ipr）' $Path (Format-Size (Get-SafeFileSize $Path))
        return
    }
    if ($DryRun) {
        $len = Get-SafeFileSize $Path
        Add-Stat $Category $len
        return
    }
    try {
        $len = Get-SafeFileSize $Path
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Add-Stat $Category $len
    } catch {
        Add-Skipped '文件被占用或无权限' $Path (Format-Size (Get-SafeFileSize $Path))
    }
}

# 移入隔离区（可恢复数据）
function Move-ToQuarantine {
    param([string]$Path, [string]$Category, [string]$Reason)

    if (Test-ProtectedPath $Path) {
        Add-Skipped '受保护的文件类型（.py/.ipynb/.md/.ipr）' $Path (Format-Size (Get-SafeFileSize $Path))
        return
    }

    $len = Get-SafeFileSize $Path
    $script:Seq++
    $name = '{0:D4}_{1}' -f $script:Seq, (Split-Path -Leaf $Path)

    if ($DryRun) {
        Add-Stat ("$Category（隔离）") $len
        $script:QuarantineItems.Add([pscustomobject]@{
            OriginalPath = $Path; QuarantinedName = $name
            SizeBytes = $len; Category = $Category; Reason = $Reason
        })
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $script:BatchDir)) {
            New-Item -ItemType Directory -Force -Path $script:BatchDir | Out-Null
        }
        $dest = Join-Path $script:BatchDir $name
        Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        Add-Stat ("$Category（隔离）") $len
        $script:QuarantineItems.Add([pscustomobject]@{
            OriginalPath = $Path; QuarantinedName = $name
            SizeBytes = $len; Category = $Category; Reason = $Reason
        })
    } catch {
        Add-Skipped '移入隔离区失败' $Path (Format-Size $len)
        $script:Errors.Add("$Path -> $($_.Exception.Message)")
    }
}

function Remove-EmptyDirs {
    param([string]$Root, [string]$ExcludeLeaf = '^dsh-')
    Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $ExcludeLeaf } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
}

# ---------------------------------------------------------------- 0. 清理过期隔离区
function Clear-ExpiredQuarantine {
    $cutoff = (Get-Date).AddDays(-$QuarantineDays)
    Get-ChildItem -LiteralPath $QuarantineDir -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $manifest = Join-Path $_.FullName 'manifest.json'
            $when = $_.CreationTime
            if (Test-Path -LiteralPath $manifest) {
                try { $when = (Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json).CreatedAt } catch { }
            }
            $when = [datetime]$when
            if ($when -lt $cutoff) {
                $size = 0
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $size += $_.Length }
                if (-not $DryRun) {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                $script:PurgedBatches.Add([pscustomobject]@{ Name = $_.Name; When = $when; Bytes = $size })
                Add-Stat '过期隔离区释放' $size
                Write-Log ("清除过期隔离批次 {0}（{1}，{2}）" -f $_.Name, $when.ToString('yyyy-MM-dd'), (Format-Size $size)) 'OK'
            }
        }
}

# ---------------------------------------------------------------- 1. 系统临时文件
function Clear-SystemTemp {
    $now  = Get-Date
    $dirs = @(
        @{ Path = Join-Path $env:LOCALAPPDATA 'Temp'; Label = '用户临时文件'; NeedAdmin = $false }
        @{ Path = 'C:\Windows\Temp';                  Label = '系统临时文件'; NeedAdmin = $true  }
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir.Path)) { continue }
        if ($dir.NeedAdmin -and -not $IsAdmin) {
            if (-not $SkipElevated) {
                $sz = 0
                Get-ChildItem -LiteralPath $dir.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $sz += $_.Length }
                Add-Skipped '需要管理员权限' $dir.Path (Format-Size $sz)
            }
            continue
        }

        $files = Get-ChildItem -LiteralPath $dir.Path -Recurse -File -Force -ErrorAction SilentlyContinue
        $n = 0
        foreach ($f in $files) {
            # 24 小时内动过的临时文件可能正被使用；跳过 DSH 会话临时目录（删掉会让工具链无法启动）
            if (($now - $f.LastWriteTime).TotalHours -lt 24) { continue }
            if ($f.FullName -match '\\dsh-[^\\]+(\\|$)') { continue }
            if ($QuarantineAll) { Move-ToQuarantine $f.FullName '临时文件' "$($dir.Label)，超过 24 小时未修改" }
            else                { Remove-RegenerableFile $f.FullName '临时文件' }
            $n++
        }
        if ($n -gt 0 -and -not $DryRun) { Remove-EmptyDirs $dir.Path }
        Write-Log ("{0}：处理 {1} 个文件" -f $dir.Label, $n)
    }
}

# ---------------------------------------------------------------- 2. Windows 更新缓存
function Clear-WindowsUpdateCache {
    $path = 'C:\Windows\SoftwareDistribution\Download'
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (-not $IsAdmin) {
        if (-not $SkipElevated) {
            $sz = 0
            Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $sz += $_.Length }
            Add-Skipped '需要管理员权限（Windows 更新缓存）' $path (Format-Size $sz)
        }
        return
    }

    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        $script:WUWasRunning = $true
        if (-not $DryRun) {
            try { Stop-Service -Name wuauserv -Force -ErrorAction Stop; Write-Log '已暂停 Windows Update 服务以便安全清理' } catch { Write-Log '无法暂停 Windows Update 服务，将跳过被锁定的文件' 'WARN' }
        }
    }

    $files = Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue
    $n = 0
    foreach ($f in $files) {
        if ($QuarantineAll) { Move-ToQuarantine $f.FullName '更新缓存' 'Windows 更新下载缓存' }
        else                { Remove-RegenerableFile $f.FullName '更新缓存' }
        $n++
    }
    if ($n -gt 0 -and -not $DryRun) { Remove-EmptyDirs $path }
    Write-Log ("Windows 更新缓存：处理 {0} 个文件" -f $n)

    if ($script:WUWasRunning -and -not $DryRun) {
        try { Start-Service -Name wuauserv -ErrorAction Stop; Write-Log 'Windows Update 服务已恢复运行' 'OK' } catch { Write-Log '恢复 Windows Update 服务失败，请手动启动 wuauserv' 'WARN' }
    }
}

# ---------------------------------------------------------------- 3. 应用与浏览器缓存
function Clear-ApplicationCache {
    $targets = @()

    foreach ($brand in @(
        @{ Name = 'Edge';   Root = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' }
        @{ Name = 'Chrome'; Root = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'   }
        @{ Name = 'Brave';  Root = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' }
    )) {
        if (-not (Test-Path -LiteralPath $brand.Root)) { continue }
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'DawnCache', 'GrShaderCache', 'ShaderCache')) {
            Get-ChildItem -LiteralPath $brand.Root -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('Default', 'Profile 1', 'Profile 2', 'Profile 3') } |
                ForEach-Object {
                    $p = Join-Path $_.FullName $sub
                    if (Test-Path -LiteralPath $p) { $targets += [pscustomobject]@{ Category = "$($brand.Name) 缓存"; Path = $p } }
                }
        }
    }

    foreach ($t in @(
        @{ Category = 'pip 缓存';        Path = Join-Path $env:LOCALAPPDATA 'pip\Cache' }
        @{ Category = 'npm 缓存';        Path = Join-Path $env:APPDATA 'npm-cache\_cacache' }
        @{ Category = 'npm 缓存(本地)';  Path = Join-Path $env:LOCALAPPDATA 'npm-cache\_cacache' }
        @{ Category = 'Yarn 缓存';       Path = Join-Path $env:LOCALAPPDATA 'Yarn\Cache' }
        @{ Category = 'NuGet 缓存';      Path = Join-Path $env:USERPROFILE '.nuget\packages' }
        @{ Category = 'VS Code 缓存';    Path = Join-Path $env:APPDATA 'Code\Cache' }
        @{ Category = 'VS Code 缓存';    Path = Join-Path $env:APPDATA 'Code\CachedData' }
    )) {
        if (Test-Path -LiteralPath $t.Path) { $targets += [pscustomobject]$t }
    }

    foreach ($t in $targets) {
        $files = Get-ChildItem -LiteralPath $t.Path -Recurse -File -Force -ErrorAction SilentlyContinue
        $n = 0
        foreach ($f in $files) {
            if ($QuarantineAll) { Move-ToQuarantine $f.FullName $t.Category '应用/浏览器缓存' }
            else                { Remove-RegenerableFile $f.FullName $t.Category }
            $n++
        }
        if ($n -gt 0) { Write-Log ("{0}：处理 {1} 个文件（{2}）" -f $t.Category, $n, $t.Path) }
    }
}

# ---------------------------------------------------------------- 4. 回收站与缩略图缓存
function Clear-RecycleBinAndThumbs {
    $before = 0
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $rb = Join-Path $drive.Root '$Recycle.Bin'
        if (-not (Test-Path -LiteralPath $rb)) { continue }
        Get-ChildItem -LiteralPath $rb -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $before += $_.Length }
    }
    if ($before -gt 0) {
        if (-not $DryRun) {
            foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                try { Clear-RecycleBin -DriveLetter $drive.Name -Force -ErrorAction Stop } catch { }
            }
        }
        Add-Stat '回收站' $before
        Write-Log ("回收站：释放 {0}" -f (Format-Size $before))
    }

    $explorerDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $explorerDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $explorerDir -File -Force -Filter '*cache_*.db' -ErrorAction SilentlyContinue)) {
            Remove-RegenerableFile $f.FullName '缩略图缓存'
        }
    }
}

# ---------------------------------------------------------------- 5. 下载目录安装包
function Clear-DownloadInstallers {
    $dir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $dir)) { return }

    $exts   = @('.exe', '.msi', '.msix', '.zip', '.7z', '.rar', '.iso', '.dmg', '.pkg', '.cab', '.msu', '.apk', '.tar', '.gz')
    $cutoff = (Get-Date).AddDays(-$InstallerAgeDays)
    $n = 0

    Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $exts -and $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Move-ToQuarantine $_.FullName '下载目录安装包' ("安装包/压缩包，{0:N0} 天未修改" -f ((Get-Date) - $_.LastWriteTime).TotalDays)
            $n++
        }

    # 下载目录里超过 90 天的临时下载残留（.crdownload/.part/.tmp）
    Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.crdownload', '.part', '.tmp', '.download') -and $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
        ForEach-Object {
            Move-ToQuarantine $_.FullName '下载目录安装包' '未完成的下载残留，超过 90 天'
            $n++
        }

    if ($n -gt 0) { Write-Log ("下载目录：处理 {0} 个安装包/残留文件" -f $n) }
}

# ---------------------------------------------------------------- 6. 重复文件
function Clear-DuplicateFiles {
    # 硬保护：不扫描「我的文档」与「桌面」（日志文件另有白名单逻辑），只处理下载、图片、视频、音乐
    $roots = @(
        (Join-Path $env:USERPROFILE 'Downloads')
        (Join-Path $env:USERPROFILE 'Pictures')
        (Join-Path $env:USERPROFILE 'Videos')
        (Join-Path $env:USERPROFILE 'Music')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $exclude = '\\node_modules\\|\\\.git\\|\\\.venv\\|\\venv\\|\\__pycache__\\|\\AppData\\|\\\$Recycle\.Bin\\|\\\.cache\\|\\site-packages\\|\\Dropbox\\|\\OneDrive\\|\\Desktop\\|\\Documents\\'
    $minBytes = $DuplicateMinMB * 1MB
    $deadline = (Get-Date).AddMinutes(6)

    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ((Get-Date) -gt $deadline) { Write-Log '重复文件扫描达到时间上限，提前结束' 'WARN'; break }
            if ($f.Length -lt $minBytes) { continue }
            if ($f.FullName -match $exclude) { continue }
            if (Test-ProtectedPath $f.FullName) { continue }
            $files.Add($f)
        }
    }

    $groups = $files | Group-Object -Property Length | Where-Object { $_.Count -gt 1 }
    $moved  = 0
    foreach ($g in $groups) {
        if ((Get-Date) -gt $deadline) { Write-Log '重复文件扫描达到时间上限，提前结束' 'WARN'; break }

        $hashes = @{}
        foreach ($f in $g.Group) {
            try {
                $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } catch { continue }
            if (-not $hashes.ContainsKey($hash)) { $hashes[$hash] = [System.Collections.Generic.List[object]]::new() }
            $hashes[$hash].Add($f)
        }

        foreach ($key in $hashes.Keys) {
            $dups = $hashes[$key]
            if ($dups.Count -lt 2) { continue }
            $keep = $dups | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            foreach ($d in ($dups | Where-Object { $_.FullName -ne $keep.FullName })) {
                Move-ToQuarantine $d.FullName '重复文件' ("与 {0} 内容相同（保留较新副本）" -f $keep.FullName)
                $moved++
            }
        }
    }
    if ($moved -gt 0) { Write-Log ("重复文件：隔离 {0} 个重复副本" -f $moved) }
}

# ---------------------------------------------------------------- 主流程
function Get-DiskFree {
    $r = @{}
    foreach ($d in 'C', 'D') {
        $p = Get-PSDrive -Name $d -ErrorAction SilentlyContinue
        if ($p) { $r[$d] = $p.Free }
    }
    return $r
}

$freeBefore = Get-DiskFree
$modeText   = if ($DryRun) { '演练模式（不删除任何文件）' } else { '实际清理' }
Write-Log ("===== 磁盘清理开始：{0}，模式：{1}，管理员：{2} =====" -f $Started.ToString('yyyy-MM-dd HH:mm:ss'), $modeText, $IsAdmin)

function Test-Category([string]$Name) { return (-not $Only) -or ($Only -contains $Name) }

Clear-ExpiredQuarantine
if (Test-Category 'Temp')       { Clear-SystemTemp }
if (Test-Category 'Update')     { Clear-WindowsUpdateCache }
if (Test-Category 'Cache')      { Clear-ApplicationCache }
if (Test-Category 'Recycle')    { Clear-RecycleBinAndThumbs }
if (Test-Category 'Installers') { Clear-DownloadInstallers }
if (Test-Category 'Duplicates') { Clear-DuplicateFiles }

# ---------------------------------------------------------------- 写隔离区清单
if (-not $DryRun -and $script:QuarantineItems.Count -gt 0) {
    $manifest = [ordered]@{
        Batch       = $Stamp
        CreatedAt   = (Get-Date).ToString('o')
        ExpiresAt   = (Get-Date).AddDays($QuarantineDays).ToString('o')
        TotalBytes  = ($script:QuarantineItems | Measure-Object SizeBytes -Sum).Sum
        TotalCount  = $script:QuarantineItems.Count
        Items       = @($script:QuarantineItems)
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:BatchDir 'manifest.json') -Encoding utf8
    Write-Log ("隔离区：{0} 个文件 / {1}，可在 {2} 内恢复" -f $script:QuarantineItems.Count,
        (Format-Size $manifest.TotalBytes), (Get-Date).AddDays($QuarantineDays).ToString('yyyy-MM-dd'))
}

# ---------------------------------------------------------------- 汇总
$directBytes  = [double]0
$quarantineBytes = [double]0
foreach ($c in $script:Stats.Keys) {
    if ($c -like '*（隔离）*') { $quarantineBytes += $script:Stats[$c].Bytes }
    else { $directBytes += $script:Stats[$c].Bytes }
}
$totalBytes = $directBytes + $quarantineBytes
$freeAfter  = Get-DiskFree

$usedBefore = $Started
$summary = [ordered]@{
    Timestamp        = (Get-Date).ToString('o')
    Mode             = if ($DryRun) { 'DryRun' } else { 'Execute' }
    IsAdmin          = $IsAdmin
    DurationSeconds  = [math]::Round(((Get-Date) - $Started).TotalSeconds, 1)
    TotalBytes       = $totalBytes
    DirectDeletedBytes = $directBytes
    QuarantinedBytes = $quarantineBytes
    QuarantinedCount = $script:QuarantineItems.Count
    TotalSizeText    = (Format-Size $totalBytes)
    Categories       = @($script:Stats.Keys | ForEach-Object {
                            [pscustomobject]@{ Name = $_; Count = $script:Stats[$_].Count; Bytes = [math]::Round($script:Stats[$_].Bytes) }
                        } | Sort-Object Bytes -Descending)
    QuarantineBatch  = if ($script:QuarantineItems.Count -gt 0 -and -not $DryRun) { $script:BatchDir } else { $null }
    QuarantineExpires = if ($script:QuarantineItems.Count -gt 0) { (Get-Date).AddDays($QuarantineDays).ToString('yyyy-MM-dd') } else { $null }
    PurgedBatches    = @($script:PurgedBatches)
    Skipped          = @($script:Skipped)
    Errors           = @($script:Errors)
    DiskFreeBefore   = @($freeBefore.Keys | ForEach-Object { [pscustomobject]@{ Drive = $_; FreeBytes = $freeBefore[$_] } })
    DiskFreeAfter    = @($freeAfter.Keys | ForEach-Object { [pscustomobject]@{ Drive = $_; FreeBytes = $freeAfter[$_] } })
}
$summaryJson = $summary | ConvertTo-Json -Depth 6
if ($SummaryPath) {
    $summaryParent = Split-Path -Parent $SummaryPath
    if ($summaryParent -and -not (Test-Path -LiteralPath $summaryParent)) { New-Item -ItemType Directory -Force -Path $summaryParent | Out-Null }
    Set-Content -LiteralPath $SummaryPath -Value $summaryJson -Encoding utf8
}
# 每次运行都归档一份；latest.* 记录正式运行，只有"演练 + 显式限定类别"的临时试跑不会覆盖它
$summaryJson | Set-Content -LiteralPath (Join-Path $ReportDir "summary-$Stamp.json") -Encoding utf8
if (-not ($DryRun -and $script:ExplicitCategories)) { $summaryJson | Set-Content -LiteralPath (Join-Path $ReportDir 'latest.json') -Encoding utf8 }

# ---------------------------------------------------------------- Markdown 报告
$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('# 磁盘清理报告')
$null = $sb.AppendLine()
$null = $sb.AppendLine("- 时间：$($Started.ToString('yyyy-MM-dd HH:mm:ss'))（耗时 $($summary.DurationSeconds) 秒）")
$null = $sb.AppendLine("- 模式：$modeText")
$null = $sb.AppendLine("- 权限：$(if ($IsAdmin) { '管理员' } else { '普通用户（跳过需提权的项目）' })")
$verb = if ($DryRun) { '预计可释放' } else { '本次释放' }
$null = $sb.AppendLine("- **$verb：$($summary.TotalSizeText)**（直接删除 $(Format-Size $directBytes)，隔离 $(Format-Size $quarantineBytes)）")
$null = $sb.AppendLine()
$null = $sb.AppendLine('## 磁盘剩余空间')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| 盘符 | 清理前 | 清理后 | 变化 |')
$null = $sb.AppendLine('| --- | --- | --- | --- |')
foreach ($b in $summary.DiskFreeBefore) {
    $a = $summary.DiskFreeAfter | Where-Object Drive -eq $b.Drive
    $diff = if ($a) { $a.FreeBytes - $b.FreeBytes } else { 0 }
    $null = $sb.AppendLine(('| {0}: | {1} | {2} | {3} |' -f $b.Drive, (Format-Size $b.FreeBytes), $(if ($a) { Format-Size $a.FreeBytes } else { '?' }), $(if ($diff -ge 0) { '+' + (Format-Size $diff) } else { '-' + (Format-Size ([math]::Abs($diff))) })))
}
$null = $sb.AppendLine()
$null = $sb.AppendLine('## 分类明细')
$null = $sb.AppendLine()
if ($summary.Categories.Count -eq 0) {
    $null = $sb.AppendLine('本次未发现可清理内容。')
} else {
    $null = $sb.AppendLine('| 类别 | 文件数 | 大小 |')
    $null = $sb.AppendLine('| --- | ---: | ---: |')
    foreach ($c in $summary.Categories) {
        $null = $sb.AppendLine(('| {0} | {1} | {2} |' -f $c.Name, $c.Count, (Format-Size $c.Bytes)))
    }
}
$null = $sb.AppendLine()
if ($script:QuarantineItems.Count -gt 0) {
    $null = $sb.AppendLine('## 隔离区（可恢复）')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("- 批次：``$Stamp``")
    $null = $sb.AppendLine("- 到期自动删除：$($summary.QuarantineExpires)")
    $null = $sb.AppendLine('- 恢复命令：`pwsh -File restore.ps1`（默认恢复最新批次，可加 `-Batch ` + 批次号）')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| 原路径 | 大小 | 原因 |')
    $null = $sb.AppendLine('| --- | ---: | --- |')
    foreach ($i in ($script:QuarantineItems | Sort-Object SizeBytes -Descending | Select-Object -First 40)) {
        $null = $sb.AppendLine(('| {0} | {1} | {2} |' -f $i.OriginalPath, (Format-Size $i.SizeBytes), ($i.Reason -replace '\|', '/')))
    }
    if ($script:QuarantineItems.Count -gt 40) { $null = $sb.AppendLine("| …… 共 $($script:QuarantineItems.Count) 项，完整清单见隔离区 manifest.json | | |") }
    $null = $sb.AppendLine()
}
if ($script:PurgedBatches.Count -gt 0) {
    $null = $sb.AppendLine('## 过期隔离批次已删除')
    $null = $sb.AppendLine()
    foreach ($p in $script:PurgedBatches) { $null = $sb.AppendLine(('- {0}（{1}，{2}）' -f $p.Name, $p.When.ToString('yyyy-MM-dd'), (Format-Size $p.Bytes))) }
    $null = $sb.AppendLine()
}
if ($script:Skipped.Count -gt 0) {
    $null = $sb.AppendLine('## 跳过项')
    $null = $sb.AppendLine()
    foreach ($s in ($script:Skipped | Select-Object -First 20)) {
        $null = $sb.AppendLine(('- {0}：`{1}` {2}' -f $s.Reason, $s.Path, $s.Size))
    }
    if ($script:Skipped.Count -gt 20) { $null = $sb.AppendLine("- …… 共 $($script:Skipped.Count) 项") }
    $null = $sb.AppendLine()
}
if ($script:Errors.Count -gt 0) {
    $null = $sb.AppendLine('## 错误')
    $null = $sb.AppendLine()
    foreach ($e in ($script:Errors | Select-Object -First 10)) { $null = $sb.AppendLine("- $e") }
    $null = $sb.AppendLine()
}
$null = $sb.AppendLine('---')
$null = $sb.AppendLine('由 `tools\disk-cleanup\cleanup.ps1` 自动生成。命令参数：`-DryRun` 演练、`-QuarantineAll` 全部隔离、`-SkipElevated` 跳过提权项。')

$reportPath = Join-Path $ReportDir 'latest.md'
if (-not ($DryRun -and $script:ExplicitCategories)) { $sb.ToString() | Set-Content -LiteralPath $reportPath -Encoding utf8 }
Set-Content -LiteralPath (Join-Path $ReportDir "report-$Stamp.md") -Value $sb.ToString() -Encoding utf8

# 历史记录
$historyCsv = Join-Path $ReportDir 'history.csv'
$row = [pscustomobject]@{
    Timestamp = $summary.Timestamp; Mode = $summary.Mode; Admin = $IsAdmin
    DirectBytes = [math]::Round($directBytes); QuarantineBytes = [math]::Round($quarantineBytes)
    TotalBytes = [math]::Round($totalBytes); DurationSeconds = $summary.DurationSeconds
}
if (Test-Path -LiteralPath $historyCsv) {
    $row | Export-Csv -LiteralPath $historyCsv -Append -NoTypeInformation -Encoding utf8
} else {
    $row | Export-Csv -LiteralPath $historyCsv -NoTypeInformation -Encoding utf8
}

Write-Log ("===== 清理完成：共 {0}，耗时 {1} 秒 =====" -f (Format-Size $totalBytes), $summary.DurationSeconds) 'OK'
if (-not $Quiet) { Write-Host "报告：$reportPath" -ForegroundColor Cyan }
