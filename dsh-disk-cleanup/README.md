# Disk cleanup

DSH plugin that gives the agent five tools for understanding and reclaiming disk space on this
computer, backed by the PowerShell engine in `scripts/`.

## Tools

| Tool | What it does |
| --- | --- |
| `disk_cleanup_scan` | Dry run: reports reclaimable total, per-category detail, admin-only targets, free space. Deletes nothing. |
| `disk_cleanup_analyze` | Storage structure: top directories, largest files, type distribution, tiered suggestions (safe / confirm / avoid), and growth since the previous analysis. Read-only. |
| `disk_cleanup_run` | Real cleanup; requires `confirm: true`. Temp files, caches, recycle bin, and Windows Update cache are deleted; installers and duplicate files are quarantined. |
| `disk_cleanup_restore` | Lists quarantine batches, or restores the newest / named batch to its original paths. |
| `disk_cleanup_status` | Latest run, quarantine batches and expiry, free space. Read-only. |

## Storage analysis

`disk_cleanup_analyze` walks the user profile (or `root`) once, time-boxed by `maxMinutes`, and writes
`reports/structure.json` plus `reports/structure.md`:

- **Top directories** — size, share of the total, file count (one level below the root)
- **Largest files** — path, size, age in days
- **Type distribution** — extension, bytes, count (top 15)
- **Suggestions** — three tiers: `safe` (regenerable), `confirm` (may hold personal files),
  `avoid` (programs, Documents, Desktop). Paths and sizes are included so the model can act.
- **Growth** — delta per directory against the previous `structure.json`

The same JSON feeds the companion Chrome extension's dashboard.


## Categories

`Temp` user and system temp files older than 24 hours · `Update` Windows Update download cache ·
`Cache` Edge/Chrome/Brave caches plus pip, npm, Yarn, NuGet, and VS Code caches · `Recycle`
recycle bin and thumbnail cache · `Installers` installer/archive files in Downloads untouched for
30 days · `Duplicates` SHA-256 duplicates of files over 10 MB in Downloads, Desktop, Documents,
Pictures, Videos, and Music, keeping the newest copy.

Pass `categories` to any of scan/run to restrict the work, e.g. `["Recycle"]`.

## Data and configuration

Everything the plugin writes lives under `%USERPROFILE%\.dsh\disk-cleanup`:

```
reports/  latest.md, latest.json, last-scan.json, last-run.json, history.csv
logs/     cleanup-<timestamp>.log
quarantine/<batch>/manifest.json + moved files, deleted after 7 days
```

Config fields (all optional, read when the plugin activates):

| Field | Default | Meaning |
| --- | --- | --- |
| `dataDir` | `%USERPROFILE%\.dsh\disk-cleanup` | Root for reports, logs, and quarantine. |
| `shellPath` | auto (`pwsh`, then `powershell`) | PowerShell executable to run the scripts with. |

## Safety

- Only allowlisted paths are touched; project folders (`node_modules`, `.git`, `venv`,
  `__pycache__`), `AppData`, and cloud-sync roots are excluded from duplicate detection.
- Regenerable data (temp files, caches, recycle bin) is deleted; recoverable data (installers,
  duplicates) is quarantined for 7 days and restorable with `disk_cleanup_restore`.
- Locked or inaccessible files are skipped and reported, never forced.
- `C:\Windows\Temp` and the Windows Update cache need an administrator session; otherwise they are
  reported as skipped. `disk_cleanup_run` refuses to act without `confirm: true`.

## Notes

- The plugin runs the scripts as the DSH host process, so it is not confined by the agent's own
  bash sandbox. Treat `disk_cleanup_run` like a deletion command: only call it with user consent.
- Disabling or removing the plugin stops the tools; it does not restore or delete anything already
  cleaned, and the quarantine directory stays until its batches expire.
