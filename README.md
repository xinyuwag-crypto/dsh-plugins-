# DSH plugins

Two local DeepSeek Harness plugins: a disk-cleanup toolkit and the workflow skill that keeps building
such tools honest.

| Package | What it does |
| --- | --- |
| [`dsh-disk-cleanup`](dsh-disk-cleanup/) | Registers four tools — `disk_cleanup_scan`, `disk_cleanup_run`, `disk_cleanup_restore`, `disk_cleanup_status` — over a PowerShell cleanup engine. Scans temp files, Windows Update cache, installers, caches, duplicates, and the recycle bin; deletes regenerable data, quarantines recoverable data for 7 days. |
| [`dsh-workflow-skill`](dsh-workflow-skill/) | Registers the `plugin-delivery-workflow` skill: an OPC-style staged workflow (target card → acceptance list → dry run → execute → rollback round-trip → packaging → operations) with gate criteria and the failure modes found while building this repo. |

## Requirements

- DeepSeek Harness with the `tools` and `skills` services (Desktop or a profile with the standard preset).
- Windows with PowerShell 7 for `dsh-disk-cleanup`.
- An administrator session if you want the system temp folder and the Windows Update cache cleaned;
  otherwise those targets are reported as skipped.

## Install

Each directory is a bundle package. In DeepSeek Harness: **Plugins** → **Add plugin** → select the
package directory (for example `dsh-disk-cleanup/`). The plugin manager installs it and enables it for
the current profile. Removing the bundle stops its tools or skill and leaves existing files alone.

```powershell
# reference: what the bundle patch inserts
Get-Content .\dsh-disk-cleanup\cordis.patch.yml
```

## Safety model (disk cleanup)

- Default category set is `Temp`, `Update`, `Cache`. `Recycle`, `Installers`, and `Duplicates` must be
  named explicitly.
- `.py`, `.ipynb`, `.md`, `.ipr` files are never deleted or quarantined; Documents and Desktop are
  never scanned for duplicates.
- `disk_cleanup_run` refuses to act without `confirm: true`.
- Quarantined files keep a `manifest.json` with original paths, and `disk_cleanup_restore` puts them back.
- Data lives under `%USERPROFILE%\.dsh\disk-cleanup` (`reports/`, `logs/`, `quarantine/`).

## License

MIT — see [LICENSE](LICENSE).
