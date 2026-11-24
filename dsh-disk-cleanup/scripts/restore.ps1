#requires -Version 5.1
<#
.SYNOPSIS
    从隔离区恢复被清理的文件（默认恢复最新一批）。
.PARAMETER DataDir
    数据根目录（含 quarantine），默认与脚本同级。
.PARAMETER Json
    以 JSON 输出结果，便于插件读取。
#>
[CmdletBinding()]
param(
    [string]$Batch,
    [switch]$List,
    [switch]$Force,
    [string]$DataDir,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ScriptDir     = Split-Path -Parent $PSCommandPath
$DataRoot      = if ($DataDir) { $DataDir } else { $ScriptDir }
$QuarantineDir = Join-Path $DataRoot 'quarantine'

$batches = @(Get-ChildItem -LiteralPath $QuarantineDir -Directory -Force -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending)

function Get-BatchInfo($dir) {
    $manifest = Join-Path $dir.FullName 'manifest.json'
    $info = [pscustomobject]@{ Batch = $dir.Name; Count = 0; Bytes = 0; ExpiresAt = $null; CreatedAt = $dir.CreationTime.ToString('o') }
    if (Test-Path -LiteralPath $manifest) {
        try {
            $j = Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json
            $info.Count = [int]$j.TotalCount
            $info.Bytes = [double]$j.TotalBytes
            $info.ExpiresAt = [string]$j.ExpiresAt
            $info.CreatedAt = [string]$j.CreatedAt
        } catch { }
    }
    return $info
}

if ($List -or -not $batches) {
    $result = [pscustomobject]@{ Action = 'list'; Batches = @($batches | ForEach-Object { Get-BatchInfo $_ }); Restored = 0; Skipped = 0; Items = @() }
    if ($Json) { $result | ConvertTo-Json -Depth 5 } else {
        if (-not $batches) { Write-Host '隔离区为空。' } else {
            Write-Host '可用隔离批次：' -ForegroundColor Cyan
            foreach ($b in $batches) {
                $i = Get-BatchInfo $b
                Write-Host ('  {0}  {1} 个文件 / {2:N1} MB，到期 {3}' -f $i.Batch, $i.Count, ($i.Bytes / 1MB), $i.ExpiresAt)
            }
        }
    }
    return
}

if (-not $Batch) { $Batch = $batches[0].Name }
$dir = Join-Path $QuarantineDir $Batch
if (-not (Test-Path -LiteralPath $dir)) { throw "批次不存在：$Batch" }

$manifestPath = Join-Path $dir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "该批次没有 manifest.json，无法恢复：$dir" }

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$restored = 0; $skipped = 0
$items = New-Object System.Collections.Generic.List[object]

foreach ($item in $manifest.Items) {
    $src  = Join-Path $dir $item.QuarantinedName
    $dest = $item.OriginalPath
    if (-not (Test-Path -LiteralPath $src)) { $skipped++; $items.Add([pscustomobject]@{ Path = $dest; Status = 'missing' }); continue }
    if ((Test-Path -LiteralPath $dest) -and -not $Force) { $skipped++; $items.Add([pscustomobject]@{ Path = $dest; Status = 'exists' }); continue }
    try {
        $parent = Split-Path -Parent $dest
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Move-Item -LiteralPath $src -Destination $dest -Force
        $restored++
        $items.Add([pscustomobject]@{ Path = $dest; Status = 'restored' })
    } catch {
        $skipped++
        $items.Add([pscustomobject]@{ Path = $dest; Status = 'failed'; Error = $_.Exception.Message })
    }
}

# 同步隔离区状态：全部恢复完则删除批次目录，否则把清单重写为"剩余项"，避免列表显示已恢复的文件
$batchCleaned = $false
$leftover = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -ne 'manifest.json' })
if ($leftover.Count -eq 0) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    $batchCleaned = $true
} else {
    $remaining = @($manifest.Items | Where-Object {
        $candidate = Join-Path $dir ([string]$_.QuarantinedName)
        Test-Path -LiteralPath $candidate
    })
    $remainingBytes = 0.0
    foreach ($r in $remaining) { $remainingBytes += [double]$r.SizeBytes }
    $updated = [ordered]@{
        Batch      = $manifest.Batch
        CreatedAt  = $manifest.CreatedAt
        ExpiresAt  = $manifest.ExpiresAt
        TotalBytes = $remainingBytes
        TotalCount = $remaining.Count
        Items      = $remaining
    }
    $updated | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8
}

$result = [pscustomobject]@{ Action = 'restore'; Batch = $Batch; Batches = @(); Restored = $restored; Skipped = $skipped; BatchCleaned = $batchCleaned; Items = $items.ToArray() }
if ($Json) {
    $result | ConvertTo-Json -Depth 5
} else {
    foreach ($i in $items) { Write-Host ('{0}: {1}' -f $i.Status, $i.Path) }
    Write-Host ''
    Write-Host ('完成：恢复 {0} 个，跳过 {1} 个。' -f $restored, $skipped) -ForegroundColor Cyan
}
