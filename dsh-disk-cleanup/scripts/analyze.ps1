#requires -Version 5.1
<#
.SYNOPSIS
    存储结构分析：目录占用、大文件、类型分布、趋势对比，并给出分档清理建议。
.DESCRIPTION
    只读扫描指定根目录（默认当前用户目录），不删除、不移动任何文件。
    输出 structure.json（稳定结构，供扩展/仪表盘读取）与 structure.md（人读报告）。
.PARAMETER Root
    扫描根目录，默认 $env:USERPROFILE。
.PARAMETER MaxMinutes
    扫描时间上限，到点即用已采集数据出报告。
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$DataDir,
    [string]$SummaryPath,
    [int]$TopDirs = 20,
    [int]$TopFiles = 20,
    [int]$MaxMinutes = 8,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

if (-not $Root) { $Root = $env:USERPROFILE }
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')

if (-not $DataDir) { $DataDir = Join-Path $env:USERPROFILE '.dsh\disk-cleanup' }
$ReportDir = Join-Path $DataDir 'reports'
if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }
if (-not $SummaryPath) { $SummaryPath = Join-Path $ReportDir 'structure.json' }

$started = Get-Date
$deadline = $started.AddMinutes($MaxMinutes)
$files = New-Object System.Collections.Generic.List[object]
$skippedDirs = New-Object System.Collections.Generic.List[object]

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

function Get-Share([double]$bytes, [double]$total) {
    if ($total -le 0) { return 0 }
    return [math]::Round($bytes / $total * 100, 1)
}

# ---------------------------------------------------------------- 枚举（单次遍历）
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($Root)
$timedOut = $false
while ($stack.Count -gt 0) {
    if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
    $dir = $stack.Pop()
    $children = $null
    try { $children = [System.IO.Directory]::EnumerateFileSystemEntries($dir) } catch {
        $skippedDirs.Add([pscustomobject]@{ Path = $dir; Reason = '无权限或不可读' })
        continue
    }
    foreach ($child in $children) {
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
        if ([System.IO.Directory]::Exists($child)) { $stack.Push($child); continue }
        try {
            $info = New-Object System.IO.FileInfo $child
            $files.Add([pscustomobject]@{
                Path          = $child
                Length        = $info.Length
                Extension     = $info.Extension.ToLowerInvariant()
                LastWriteTime = $info.LastWriteTime
            })
        } catch { }
    }
}
if ($timedOut) { $skippedDirs.Add([pscustomobject]@{ Path = '(time limit)'; Reason = ('扫描达到 {0} 分钟上限，剩余目录未统计' -f $MaxMinutes) }) }

# ---------------------------------------------------------------- 聚合
$totalBytes = 0.0
foreach ($f in $files) { $totalBytes += $f.Length }
$totalCount = $files.Count

$dirStats = @{}
foreach ($f in $files) {
    $rel = $f.Path.Substring($Root.Length).TrimStart('\')
    $parts = $rel.Split('\')
    $key = if ($parts.Length -gt 1) { $parts[0] } else { '(files in root)' }
    if (-not $dirStats.ContainsKey($key)) { $dirStats[$key] = @{ Bytes = [double]0; Count = 0 } }
    $dirStats[$key].Bytes += $f.Length
    $dirStats[$key].Count++
}

$dirRows = New-Object System.Collections.Generic.List[object]
foreach ($entry in $dirStats.GetEnumerator()) {
    $dirRows.Add([pscustomobject]@{
        Name  = $entry.Key
        Path  = (Join-Path $Root $entry.Key)
        Bytes = [math]::Round($entry.Value.Bytes)
        Files = $entry.Value.Count
        Share = (Get-Share $entry.Value.Bytes $totalBytes)
    })
}
$dirsOut = $dirRows | Sort-Object Bytes -Descending | Select-Object -First $TopDirs

$filesOut = $files | Sort-Object Length -Descending | Select-Object -First $TopFiles |
    ForEach-Object {
        [pscustomobject]@{
            Path     = $_.Path
            Bytes    = $_.Length
            Modified = $_.LastWriteTime.ToString('yyyy-MM-dd')
            AgeDays  = [int]((Get-Date) - $_.LastWriteTime).TotalDays
        }
    }

$extRows = New-Object System.Collections.Generic.List[object]
foreach ($g in ($files | Group-Object Extension)) {
    $sum = [double]0
    foreach ($x in $g.Group) { $sum += $x.Length }
    $extRows.Add([pscustomobject]@{
        Extension = if ($g.Name) { $g.Name } else { '(no extension)' }
        Count     = $g.Count
        Bytes     = [math]::Round($sum)
        Share     = (Get-Share $sum $totalBytes)
    })
}
$extOut = $extRows | Sort-Object Bytes -Descending | Select-Object -First 15

# ---------------------------------------------------------------- 建议规则
$suggestions = New-Object System.Collections.Generic.List[object]
function Add-Suggestion([string]$Tier, [string]$Title, [string]$Detail, [string]$Path, [double]$Bytes) {
    $suggestions.Add([pscustomobject]@{
        Tier   = $Tier
        Title  = $Title
        Detail = $Detail
        Path   = $Path
        Bytes  = [math]::Round($Bytes)
    })
}

$rules = [ordered]@{
    'AppData\Local\Temp'           = @('safe', '临时文件', '超过 24 小时未修改即可安全删除')
    'AppData\Local\Microsoft\Edge' = @('safe', 'Edge 缓存', '仅清理 User Data 下的 Cache / Code Cache / GPUCache')
    'AppData\Local\Google\Chrome'  = @('safe', 'Chrome 缓存', '仅清理 User Data 下的 Cache 目录')
    'AppData\Local\pip'            = @('safe', 'pip 缓存', '可随时重建')
    'AppData\Local\npm-cache'      = @('safe', 'npm 缓存', '可随时重建')
    'Downloads'                    = @('confirm', '下载目录', '以安装包与压缩包为主，确认后再清理')
    'AppData\Local\Packages'       = @('confirm', 'UWP 应用数据', '部分应用数据删除后需要重新登录')
    'AppData\Local\Programs'       = @('avoid', '已安装程序', '程序本体，删除会导致无法启动')
    'Documents'                    = @('avoid', '我的文档', '个人文件，不在清理范围内')
    'Desktop'                      = @('avoid', '桌面', '个人文件，不在清理范围内')
}

foreach ($key in $rules.Keys) {
    $full = Join-Path $Root $key
    $sum = [double]0
    $matched = $false
    foreach ($f in $files) {
        if ($f.Path.StartsWith($full, [System.StringComparison]::OrdinalIgnoreCase)) { $sum += $f.Length; $matched = $true }
    }
    if (-not $matched -or $sum -lt 50MB) { continue }
    $meta = $rules[$key]
    Add-Suggestion $meta[0] $meta[1] $meta[2] $full $sum
}

foreach ($f in $filesOut) {
    if ($f.Bytes -ge 1GB) {
        Add-Suggestion 'confirm' '大文件' ('单个文件 {0}，确认是否仍需要' -f (Format-Size $f.Bytes)) $f.Path $f.Bytes
    }
}

# ---------------------------------------------------------------- 趋势对比
$previous = $null
if (Test-Path -LiteralPath $SummaryPath) {
    try { $previous = Get-Content -LiteralPath $SummaryPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
}

$growth = New-Object System.Collections.Generic.List[object]
if ($previous -and $previous.TopDirs) {
    $prevMap = @{}
    foreach ($d in $previous.TopDirs) { $prevMap[$d.Name] = [double]$d.Bytes }
    foreach ($row in $dirsOut) {
        $old = 0.0
        if ($prevMap.ContainsKey($row.Name)) { $old = $prevMap[$row.Name] }
        $growth.Add([pscustomobject]@{
            Name          = $row.Name
            Bytes         = $row.Bytes
            PreviousBytes = [math]::Round($old)
            DeltaBytes    = [math]::Round($row.Bytes - $old)
        })
    }
}
$growthOut = $growth | Sort-Object DeltaBytes -Descending | Select-Object -First 5

# ---------------------------------------------------------------- 输出
$suggOut = $suggestions | Sort-Object Bytes -Descending
$summary = [ordered]@{
    Timestamp       = (Get-Date).ToString('o')
    Root            = $Root
    DurationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    TotalBytes      = [math]::Round($totalBytes)
    TotalFiles      = $totalCount
    TopDirs         = @($dirsOut)
    TopFiles        = @($filesOut)
    ByExtension     = @($extOut)
    Suggestions     = @($suggOut)
    Growth          = @($growthOut)
    Skipped         = $skippedDirs.ToArray()
    Legend          = [ordered]@{
        safe    = '可安全清理，重新生成成本低'
        confirm = '需确认后清理，可能含个人文件'
        avoid   = '不建议清理'
    }
}
$json = $summary | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $SummaryPath -Value $json -Encoding utf8

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# 存储结构分析')
[void]$sb.AppendLine()
[void]$sb.AppendLine(('- 扫描根：{0}' -f $Root))
[void]$sb.AppendLine(('- 时间：{0}（耗时 {1} 秒）' -f $started.ToString('yyyy-MM-dd HH:mm:ss'), $summary.DurationSeconds))
[void]$sb.AppendLine(('- 总量：{0}，共 {1:N0} 个文件' -f (Format-Size $totalBytes), $totalCount))
[void]$sb.AppendLine()
[void]$sb.AppendLine('## 目录占用 Top')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| 目录 | 大小 | 占比 | 文件数 |')
[void]$sb.AppendLine('| --- | ---: | ---: | ---: |')
foreach ($d in $dirsOut) { [void]$sb.AppendLine(('| {0} | {1} | {2}% | {3} |' -f $d.Name, (Format-Size $d.Bytes), $d.Share, $d.Files)) }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## 类型分布')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| 类型 | 大小 | 占比 | 数量 |')
[void]$sb.AppendLine('| --- | ---: | ---: | ---: |')
foreach ($e in $extOut) { [void]$sb.AppendLine(('| {0} | {1} | {2}% | {3} |' -f $e.Extension, (Format-Size $e.Bytes), $e.Share, $e.Count)) }
[void]$sb.AppendLine()
[void]$sb.AppendLine('## 清理建议')
[void]$sb.AppendLine()
foreach ($s in $suggOut) {
    [void]$sb.AppendLine(('- **[{0}] {1}**（{2}）：{3}' -f $s.Tier, $s.Title, (Format-Size $s.Bytes), $s.Detail))
    [void]$sb.AppendLine(('  `{0}`' -f $s.Path))
}
[void]$sb.AppendLine()
if ($growthOut -and @($growthOut).Count -gt 0) {
    [void]$sb.AppendLine('## 增长最快')
    [void]$sb.AppendLine()
    foreach ($g in $growthOut) {
        $delta = $g.DeltaBytes / 1GB
        [void]$sb.AppendLine(('- {0}：{1} → {2}（{3}{4:N2} GB）' -f $g.Name, (Format-Size $g.PreviousBytes), (Format-Size $g.Bytes), $(if ($delta -ge 0) { '+' } else { '-' }), [math]::Abs($delta)))
    }
    [void]$sb.AppendLine()
}
Set-Content -LiteralPath (Join-Path $ReportDir 'structure.md') -Value $sb.ToString() -Encoding utf8

if (-not $Quiet) { $sb.ToString() | Write-Output }
