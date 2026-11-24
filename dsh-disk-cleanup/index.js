import { spawn } from 'node:child_process'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const scripts = path.join(here, 'scripts')

export const inject = ['tools']

const CATEGORIES = ['Temp', 'Update', 'Cache', 'Recycle', 'Installers', 'Duplicates']
// 未显式指定类别时只处理安全三项；Recycle / Installers / Duplicates 必须点名开启
const DEFAULT_CATEGORIES = ['Temp', 'Update', 'Cache']
const RUN_TIMEOUT_MS = 30 * 60 * 1000
const STREAM_CAP = 64 * 1024

function dataDirOf(config) {
  const raw = typeof config?.dataDir === 'string' ? config.dataDir.trim() : ''
  return raw ? path.resolve(raw) : path.join(os.homedir(), '.dsh', 'disk-cleanup')
}

function shellsOf(config) {
  const configured = typeof config?.shellPath === 'string' && config.shellPath.trim() ? [config.shellPath.trim()] : []
  return [...configured, 'pwsh', 'powershell']
}

function tail(text, limit = 1200) {
  if (!text) return ''
  const trimmed = text.trim()
  return trimmed.length <= limit ? trimmed : `…${trimmed.slice(-limit)}`
}

/** Run one PowerShell script file, trying the next shell candidate when one is missing. */
async function runPowerShell(file, args, { signal, config } = {}) {
  const failures = []
  for (const shell of shellsOf(config)) {
    try {
      return await new Promise((resolve, reject) => {
        const child = spawn(
          shell,
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, ...args],
          { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
        )
        let stdout = ''
        let stderr = ''
        let settled = false
        const timer = setTimeout(() => {
          if (settled) return
          settled = true
          try { child.kill() } catch { /* already gone */ }
          reject(new Error(`${path.basename(file)} timed out after ${Math.round(RUN_TIMEOUT_MS / 60000)} minutes`))
        }, RUN_TIMEOUT_MS)
        const onAbort = () => { try { child.kill() } catch { /* already gone */ } }
        signal?.addEventListener('abort', onAbort, { once: true })

        const finish = (fn, value) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          signal?.removeEventListener('abort', onAbort)
          fn(value)
        }

        child.stdout?.on('data', (chunk) => {
          stdout += chunk.toString()
          if (stdout.length > STREAM_CAP * 4) stdout = stdout.slice(-STREAM_CAP)
        })
        child.stderr?.on('data', (chunk) => {
          stderr += chunk.toString()
          if (stderr.length > STREAM_CAP * 4) stderr = stderr.slice(-STREAM_CAP)
        })
        child.on('error', (error) => finish(reject, error))
        child.on('close', (code) => finish(resolve, { code, stdout, stderr, shell }))
      })
    } catch (error) {
      if (error && error.code === 'ENOENT') {
        failures.push(`${shell}: not found`)
        continue
      }
      throw error
    }
  }
  throw new Error(`PowerShell not available (${failures.join(', ')})`)
}

function formatBytes(bytes) {
  const n = Number(bytes) || 0
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(2)} GB`
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MB`
  if (n >= 1024) return `${(n / 1024).toFixed(0)} KB`
  return `${n.toFixed(0)} B`
}

async function readJson(file) {
  try {
    return JSON.parse(await fsp.readFile(file, 'utf8'))
  } catch {
    return undefined
  }
}

function normalizeRun(raw, extra) {
  const categories = Array.isArray(raw?.Categories)
    ? raw.Categories.map((c) => ({ name: c.Name, count: c.Count, bytes: c.Bytes, text: formatBytes(c.Bytes) }))
    : []
  const skipped = Array.isArray(raw?.Skipped)
    ? raw.Skipped.map((s) => ({ reason: s.Reason, path: s.Path, size: s.Size }))
    : []
  const before = Array.isArray(raw?.DiskFreeBefore) ? raw.DiskFreeBefore : []
  const diskFree = Array.isArray(raw?.DiskFreeAfter)
    ? raw.DiskFreeAfter.map((d) => ({
        drive: `${d.Drive}:`,
        freeBytes: d.FreeBytes,
        freeText: formatBytes(d.FreeBytes),
        gainedBytes: typeof before.find((b) => b.Drive === d.Drive)?.FreeBytes === 'number'
          ? d.FreeBytes - before.find((b) => b.Drive === d.Drive).FreeBytes
          : null,
      }))
    : []
  return {
    mode: extra.mode,
    dataDir: extra.dataDir,
    reportPath: extra.reportPath,
    durationSeconds: raw?.DurationSeconds ?? null,
    isAdmin: raw?.IsAdmin ?? false,
    totalBytes: raw?.TotalBytes ?? 0,
    totalText: formatBytes(raw?.TotalBytes ?? 0),
    directlyDeletedBytes: raw?.DirectDeletedBytes ?? 0,
    quarantinedBytes: raw?.QuarantinedBytes ?? 0,
    quarantinedCount: raw?.QuarantinedCount ?? 0,
    quarantineBatch: raw?.QuarantineBatch ?? null,
    quarantineExpires: raw?.QuarantineExpires ?? null,
    categories,
    skipped,
    diskFree,
    errors: Array.isArray(raw?.Errors) ? raw.Errors.slice(0, 5) : [],
  }
}

function renderRun(value) {
  const lines = []
  if (value.mode === 'scan') {
    lines.push(`Scan: ${value.totalText} reclaimable across ${value.categories.length} categories (${value.durationSeconds ?? '?'} s, nothing deleted).`)
  } else {
    lines.push(
      `Cleanup: ${value.totalText} freed — ${formatBytes(value.directlyDeletedBytes)} deleted, ` +
        `${formatBytes(value.quarantinedBytes)} in ${value.quarantinedCount} quarantined file(s).`,
    )
  }
  for (const category of value.categories) lines.push(`  - ${category.name}: ${category.count} files, ${category.text}`)
  if (value.quarantineBatch) {
    lines.push(`Quarantine batch ${value.quarantineBatch} is restorable until ${value.quarantineExpires}.`)
  }
  const adminSkipped = value.skipped.filter((item) => /admin|管理员/i.test(item.reason))
  if (adminSkipped.length) {
    lines.push('Skipped, needs administrator:')
    for (const item of adminSkipped) lines.push(`  - ${item.path} ${item.size}`)
  }
  const otherSkipped = value.skipped.filter((item) => !/admin|管理员/i.test(item.reason))
  if (otherSkipped.length) lines.push(`Also skipped: ${otherSkipped.length} locked or inaccessible item(s).`)
  for (const disk of value.diskFree ?? []) lines.push(`${disk.drive} free: ${disk.freeText}`)
  if (value.errors?.length) lines.push(`Errors: ${value.errors.join(' | ')}`)
  lines.push(`Report: ${value.reportPath}`)
  return [{ type: 'text', text: lines.join('\n') }]
}

async function runCleanup(config, options, signal) {
  const dataDir = dataDirOf(config)
  const reports = path.join(dataDir, 'reports')
  await fsp.mkdir(reports, { recursive: true })
  const summaryPath = path.join(reports, options.mode === 'scan' ? 'last-scan.json' : 'last-run.json')

  const args = ['-DataDir', dataDir, '-SummaryPath', summaryPath, '-Quiet']
  if (options.mode === 'scan') args.push('-DryRun')
  if (options.categories?.length) args.push('-Categories', options.categories.join(','))
  if (Number.isFinite(options.quarantineDays)) args.push('-QuarantineDays', String(options.quarantineDays))
  if (Number.isFinite(options.installerAgeDays)) args.push('-InstallerAgeDays', String(options.installerAgeDays))
  if (Number.isFinite(options.duplicateMinMB)) args.push('-DuplicateMinMB', String(options.duplicateMinMB))

  const result = await runPowerShell(path.join(scripts, 'cleanup.ps1'), args, { signal, config })
  const raw = await readJson(summaryPath)
  if (!raw) {
    throw new Error(
      `cleanup.ps1 exited with code ${result.code} and wrote no summary. ${tail(result.stderr) || tail(result.stdout)}`,
    )
  }
  return normalizeRun(raw, { mode: options.mode, dataDir, reportPath: path.join(reports, 'latest.md') })
}

async function listQuarantine(config) {
  const root = path.join(dataDirOf(config), 'quarantine')
  let entries = []
  try {
    entries = await fsp.readdir(root, { withFileTypes: true })
  } catch {
    return []
  }
  const batches = []
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    const manifest = await readJson(path.join(root, entry.name, 'manifest.json'))
    batches.push({
      batch: entry.name,
      count: manifest?.TotalCount ?? 0,
      bytes: manifest?.TotalBytes ?? 0,
      text: formatBytes(manifest?.TotalBytes ?? 0),
      expiresAt: manifest?.ExpiresAt ?? null,
    })
  }
  return batches.sort((a, b) => (a.batch < b.batch ? 1 : -1))
}

async function diskSpace() {
  const drives = process.platform === 'win32' ? ['C', 'D', 'E'] : ['/']
  const free = []
  for (const drive of drives) {
    const target = drive === '/' ? '/' : `${drive}:\\`
    try {
      if (typeof fsp.statfs !== 'function') return free
      const info = await fsp.statfs(target)
      const bytes = Number(info.bsize) * Number(info.bavail)
      if (!bytes) continue
      free.push({ drive: drive === '/' ? '/' : `${drive}:`, freeBytes: bytes, freeText: formatBytes(bytes) })
    } catch {
      // Drive unreadable or absent.
    }
  }
  return free
}

export function apply(ctx, config = {}) {
  const dataDir = dataDirOf(config)

  ctx.effect(() => ctx.tools.register({
    name: 'disk_cleanup_scan',
    description:
      'Scan this computer for reclaimable files — temp files, Windows Update cache, installer packages in Downloads, ' +
      'application and browser caches, duplicate files, recycle bin — without deleting anything. Returns the reclaimable ' +
      'total, per-category detail, items skipped for lack of administrator rights, and current free space.',
    parameters: {
      type: 'object',
      properties: {
        categories: {
          type: 'array',
          items: { type: 'string', enum: CATEGORIES },
          description: 'Restrict the scan to these categories. Defaults to Temp, Update, and Cache; name the others explicitly.',
        },
      },
      additionalProperties: false,
    },
    output: {
      schema: { type: 'object', description: 'Scan totals, categories, skipped items, free space, report path.' },
      render: (_args, value) => renderRun(value),
    },
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      return runCleanup(config, {
        mode: 'scan',
        categories: args?.categories?.length ? args.categories : DEFAULT_CATEGORIES,
      }, exec.signal)
    },
  }))

  ctx.effect(() => ctx.tools.register({
    name: 'disk_cleanup_run',
    description:
      'Clean reclaimable residue and quarantine recoverable files on this computer. Temp files, application caches, the ' +
      'recycle bin, and the Windows Update cache are deleted; installer packages and duplicate files are moved into a ' +
      'quarantine directory that disk_cleanup_restore can restore. Defaults to the safe set Temp, Update, and Cache. ' +
      'Never cleans .py, .ipynb, .md, or .ipr files, and never scans Documents or Desktop. Requires confirm: true because ' +
      'it changes files on disk.',
    parameters: {
      type: 'object',
      properties: {
        confirm: {
          type: 'boolean',
          description: 'Must be true. Set it only after the user authorizes deleting files on this computer.',
        },
        categories: {
          type: 'array',
          items: { type: 'string', enum: CATEGORIES },
          description: 'Restrict the run to these categories. Defaults to Temp, Update, and Cache; name Recycle, Installers, or Duplicates explicitly to include them.',
        },
        quarantineDays: {
          type: 'integer',
          description: 'Days quarantined files are kept before permanent deletion. Defaults to 7.',
        },
        installerAgeDays: {
          type: 'integer',
          description: 'Only quarantine installer or archive files in Downloads untouched for this many days. Defaults to 30.',
        },
        duplicateMinMB: {
          type: 'integer',
          description: 'Smallest file size compared when detecting duplicates, in MB. Defaults to 10.',
        },
      },
      required: ['confirm'],
      additionalProperties: false,
    },
    output: {
      schema: { type: 'object', description: 'Freed bytes, categories, quarantine batch, skipped items, free space.' },
      render: (_args, value) => renderRun(value),
    },
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      if (args?.confirm !== true) {
        throw new Error(
          'Refusing to clean: pass confirm: true only after the user authorizes deleting files on this computer.',
        )
      }
      return runCleanup(config, {
        mode: 'execute',
        categories: args.categories?.length ? args.categories : DEFAULT_CATEGORIES,
        quarantineDays: args.quarantineDays,
        installerAgeDays: args.installerAgeDays,
        duplicateMinMB: args.duplicateMinMB,
      }, exec.signal)
    },
  }))

  ctx.effect(() => ctx.tools.register({
    name: 'disk_cleanup_restore',
    description:
      'List quarantine batches or restore files that a cleanup moved away. With listOnly it reports batches and their ' +
      'expiry. Otherwise it moves the newest batch, or the batch named by batch, back to the original paths and skips ' +
      'paths that already exist.',
    parameters: {
      type: 'object',
      properties: {
        listOnly: { type: 'boolean', description: 'Only list quarantine batches; restore nothing.' },
        batch: { type: 'string', description: 'Batch directory name as returned by listOnly. Defaults to the newest batch.' },
        force: { type: 'boolean', description: 'Overwrite a file that already exists at the original path.' },
      },
      additionalProperties: false,
    },
    output: {
      schema: { type: 'object', description: 'Restore result: batch, restored and skipped counts, per-path status.' },
      render: (_args, value) => {
        const lines = []
        if (value.action === 'list') {
          lines.push(value.batches.length ? `Quarantine batches (${value.batches.length}):` : 'Quarantine is empty.')
          for (const batch of value.batches) {
            lines.push(`  - ${batch.batch}: ${batch.count} files, ${batch.text}, expires ${batch.expiresAt ?? 'unknown'}`)
          }
        } else {
          lines.push(`Restored ${value.restored} file(s) from ${value.batch ?? 'the newest batch'}; ${value.skipped} skipped.`)
          for (const item of value.items.filter((entry) => entry.status !== 'restored').slice(0, 10)) {
            lines.push(`  - ${item.status}: ${item.path}`)
          }
          if (value.batchCleaned) lines.push('Quarantine batch is now empty and was removed.')
          else if (value.remaining > 0) lines.push(`${value.remaining} file(s) still quarantined in this batch.`)
        }
        return [{ type: 'text', text: lines.join('\n') }]
      },
    },
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      const cli = ['-DataDir', dataDir, '-Json']
      if (args?.listOnly) cli.push('-List')
      if (args?.batch) cli.push('-Batch', String(args.batch))
      if (args?.force) cli.push('-Force')
      const result = await runPowerShell(path.join(scripts, 'restore.ps1'), cli, { signal: exec.signal, config })
      const text = result.stdout.trim()
      try {
        const parsed = JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1))
        return {
          action: parsed.Action === 'list' ? 'list' : 'restore',
          batch: parsed.Batch ?? null,
          batches: (parsed.Batches ?? []).map((batch) => ({
            batch: batch.Batch ?? batch.batch ?? '',
            count: batch.Count ?? batch.count ?? 0,
            bytes: batch.Bytes ?? batch.bytes ?? 0,
            text: formatBytes(batch.Bytes ?? batch.bytes ?? 0),
            expiresAt: batch.ExpiresAt ?? batch.expiresAt ?? null,
          })),
          restored: parsed.Restored ?? 0,
          skipped: parsed.Skipped ?? 0,
          batchCleaned: parsed.BatchCleaned ?? false,
          remaining: Math.max(0, (parsed.Items?.length ?? 0) - (parsed.Restored ?? 0)),
          items: (parsed.Items ?? []).map((item) => ({
            path: item.Path ?? item.path ?? '',
            status: item.Status ?? item.status ?? '',
            error: item.Error ?? item.error ?? null,
          })),
        }
      } catch {
        throw new Error(
          `restore.ps1 exited with code ${result.code} and returned no JSON. ${tail(result.stderr) || tail(text)}`,
        )
      }
    },
  }))

  ctx.effect(() => ctx.tools.register({
    name: 'disk_cleanup_analyze',
    description:
      'Analyze how storage is structured on this computer: directory sizes, largest files, file-type distribution, and ' +
      'tiered cleanup suggestions (safe to clear / confirm first / do not touch), compared with the previous analysis. ' +
      'Read-only; it never deletes or moves anything.',
    parameters: {
      type: 'object',
      properties: {
        root: { type: 'string', description: 'Directory to analyze. Defaults to the user profile.' },
        topFiles: { type: 'integer', description: 'How many of the largest files to report. Defaults to 20.' },
        maxMinutes: { type: 'integer', description: 'Scan time budget in minutes. Defaults to 8.' },
      },
      additionalProperties: false,
    },
    output: {
      schema: { type: 'object', description: 'Totals, top directories, largest files, type distribution, tiered suggestions, growth.' },
      render: (_args, value) => {
        const lines = []
        lines.push(
          `Storage under ${value.root}: ${value.totalText} across ${value.totalFiles.toLocaleString()} files ` +
            `(scanned in ${value.durationSeconds}s).`,
        )
        lines.push('Top directories:')
        for (const dir of value.topDirs.slice(0, 8)) {
          lines.push(`  - ${dir.name}: ${dir.text} (${dir.share}%, ${dir.files} files)`)
        }
        if (value.suggestions.length) {
          lines.push('Cleanup suggestions:')
          for (const s of value.suggestions.slice(0, 10)) {
            lines.push(`  - [${s.tier}] ${s.title} — ${s.text}: ${s.detail}`)
          }
        }
        if (value.growth.length) {
          lines.push('Growth since last analysis:')
          for (const g of value.growth.slice(0, 5)) {
            lines.push(`  - ${g.name}: ${g.deltaText}`)
          }
        }
        lines.push(`Report: ${value.reportPath}`)
        return [{ type: 'text', text: lines.join('\n') }]
      },
    },
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      const summaryPath = path.join(dataDir, 'reports', 'structure.json')
      const cli = ['-DataDir', dataDir, '-SummaryPath', summaryPath, '-Quiet']
      if (args?.root) cli.push('-Root', String(args.root))
      if (args?.topFiles) cli.push('-TopFiles', String(args.topFiles))
      if (args?.maxMinutes) cli.push('-MaxMinutes', String(args.maxMinutes))

      const result = await runPowerShell(path.join(scripts, 'analyze.ps1'), cli, { signal: exec.signal, config })
      const raw = await readJson(summaryPath)
      if (!raw) {
        throw new Error(
          `analyze.ps1 exited with code ${result.code} and wrote no structure.json. ${tail(result.stderr) || tail(result.stdout)}`,
        )
      }
      const dirs = (raw.TopDirs ?? []).map((d) => ({
        name: d.Name, path: d.Path, bytes: d.Bytes, text: formatBytes(d.Bytes), files: d.Files, share: d.Share,
      }))
      const files = (raw.TopFiles ?? []).map((f) => ({
        path: f.Path, bytes: f.Bytes, text: formatBytes(f.Bytes), ageDays: f.AgeDays,
      }))
      const exts = (raw.ByExtension ?? []).map((e) => ({
        extension: e.Extension, count: e.Count, bytes: e.Bytes, text: formatBytes(e.Bytes), share: e.Share,
      }))
      const suggestions = (raw.Suggestions ?? []).map((s) => ({
        tier: s.Tier, title: s.Title, detail: s.Detail, path: s.Path, bytes: s.Bytes, text: formatBytes(s.Bytes),
      }))
      const growth = (raw.Growth ?? []).map((g) => ({
        name: g.Name,
        bytes: g.Bytes,
        previousBytes: g.PreviousBytes,
        deltaBytes: g.DeltaBytes,
        deltaText: `${g.DeltaBytes >= 0 ? '+' : '-'}${formatBytes(Math.abs(g.DeltaBytes))}`,
      }))
      return {
        root: raw.Root,
        durationSeconds: raw.DurationSeconds,
        totalBytes: raw.TotalBytes,
        totalText: formatBytes(raw.TotalBytes),
        totalFiles: raw.TotalFiles,
        topDirs: dirs,
        topFiles: files,
        byExtension: exts,
        suggestions,
        growth,
        skipped: (raw.Skipped ?? []).map((s) => ({ path: s.Path, reason: s.Reason })),
        reportPath: path.join(dataDir, 'reports', 'structure.md'),
      }
    },
  }))

  ctx.effect(() => ctx.tools.register({
    name: 'disk_cleanup_status',
    description:
      'Report the latest cleanup result, quarantine batches and their expiry, and current free space. Reads the cleanup ' +
      'data directory only and changes nothing.',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    output: {
      schema: { type: 'object', description: 'Latest run, quarantine batches, free space, data directory.' },
      render: (_args, value) => {
        const lines = []
        if (value.lastRun) {
          lines.push(
            `Last ${value.lastRun.mode === 'scan' ? 'scan' : 'cleanup'}: ${value.lastRun.totalText} ` +
              `${value.lastRun.mode === 'scan' ? 'reclaimable' : 'freed'} at ${value.lastRun.timestamp ?? 'unknown'}.`,
          )
        } else {
          lines.push('No cleanup run recorded in this data directory yet.')
        }
        lines.push(
          value.batches.length
            ? `Quarantine: ${value.batches.length} batch(es), ${value.batches.reduce((sum, batch) => sum + batch.count, 0)} files.`
            : 'Quarantine: empty.',
        )
        for (const batch of value.batches.slice(0, 5)) {
          lines.push(`  - ${batch.batch}: ${batch.text}, expires ${batch.expiresAt ?? 'unknown'}`)
        }
        for (const disk of value.diskFree) lines.push(`${disk.drive} free: ${disk.freeText}`)
        lines.push(`Data directory: ${value.dataDir}`)
        return [{ type: 'text', text: lines.join('\n') }]
      },
    },
    async execute() {
      const executed = await readJson(path.join(dataDir, 'reports', 'last-run.json'))
      const source = executed ?? await readJson(path.join(dataDir, 'reports', 'last-scan.json'))
      return {
        dataDir,
        lastRun: source
          ? {
              mode: executed ? 'execute' : 'scan',
              timestamp: source.Timestamp ?? null,
              totalBytes: source.TotalBytes ?? 0,
              totalText: formatBytes(source.TotalBytes ?? 0),
              categories: (source.Categories ?? []).map((c) => ({ name: c.Name, count: c.Count, bytes: c.Bytes })),
            }
          : null,
        batches: await listQuarantine(config),
        diskFree: await diskSpace(),
        errors: source?.Errors ?? [],
      }
    },
  }))
}
