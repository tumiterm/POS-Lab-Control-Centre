# Phase 0 — Lab Discovery

> **Script execution is blocked by policy on our machines.** Do **not** work around it.
> Use the [manual checklist](#manual-checklist-no-scripts) below. The script stays here
> for when it can be run through an approved channel (signed by Cybersecurity, or run
> as a task in an existing TFS release pipeline with the pipeline owner's approval).

`Invoke-LabDiscovery.ps1` is a **read-only** script that collects the facts we need to design
the monitoring agent: RDP sessions, installed component versions, services, lab
configuration and MDD (Change Tracking Queue Import Services) evidence.

## Run it

On one dev lab **and** on the prod baseline lab `Compatible (030310)` (for before/after):

```powershell
# Open PowerShell as Administrator
powershell -ExecutionPolicy Bypass -File .\Invoke-LabDiscovery.ps1

# Optional: also read local SQL Server metadata (Windows auth, read-only)
powershell -ExecutionPolicy Bypass -File .\Invoke-LabDiscovery.ps1 -IncludeSqlProbe
```

Output goes to your Desktop: `LabDiscovery_<MACHINE>_<timestamp>\` plus a `.zip`.

- `summary.txt` — quick human-readable overview
- `discovery.json` — everything structured
- `raw\` — quser/qwinsta output, all installed programs, MDD configs and log tails

## What it does NOT do

- Change, start, stop or restart anything
- Write to any database (SQL probe runs `SELECT` on system views only)
- Send data anywhere

Passwords, tokens and keys in config / connection strings are redacted, but please
**review the output before sharing**.

## What we want to learn

| Question | Where to look |
|---|---|
| Single- or multi-session OS? | `machine.osProductType`, `sessions` |
| Where is each component's version? | `installedPrograms`, `fileVersions`, `services[].exeVersion` |
| Does installed version = TFS build number (`26.10.0201`)? | compare the above with TFS |
| Where are country / branch / store? | `configCandidates` |
| How can we tell MDD is actually syncing? | `mddFolder` (logs, configs), `eventLogs`, `scheduledTasks`, `sql.probe` |

## Manual checklist (no scripts)

About 15 minutes on one dev lab and on `Compatible (030310)`. Screenshots are fine.
Every step uses built-in tools only; nothing is installed or changed.

| # | Check | How | Tells us |
|---|---|---|---|
| 1 | **Can I see sessions remotely?** (most important) | From **your own PC**, in a normal command prompt: `quser /server:<LABMACHINE>` | If this works, the central app may detect occupancy **without any agent** |
| 2 | Sessions on the lab | On the lab: `quser` | Session format, Active/Disc states |
| 3 | OS edition | `winver` | Windows 10/11 (one user at a time) vs Server |
| 4 | Installed components | Control Panel → Programs and Features, sort by Publisher; screenshot TFG/Store/POS rows incl. **Version** | Whether versions are readable from the registry |
| 5 | Exe versions | `C:\Program Files\TFG\…` → right-click the POS exe and the Store Services exe → Properties → Details | Whether file version = TFS build number (e.g. `26.10.0201`) |
| 6 | Services | `services.msc`, sort by name; screenshot TFG/Store/POS/Change Tracking services (status, startup type, Log On As) | Service list to monitor |
| 7 | MDD folder | Open `C:\Program Files\TFG\SQL\Change Tracking Queue Import Services` in Explorer (Details view with *Date modified*) | Files, logs, configs |
| 8 | MDD logs | Open the newest log in Notepad; note how a successful import and an error look (copy a few lines, **remove** server names/passwords) | How to detect "actually syncing" |
| 9 | MDD config | Open the `.config`; note which DB/Head Office it points to, any interval/batch settings (**don't** share passwords) | Thresholds and data source |
| 10 | Event Viewer | Windows Logs → Application; filter by sources containing TFG/Store/Change Tracking | Errors we can alert on |
| 11 | Lab config | Ask a POS dev: where are country / branch / store set on a lab (config file, registry, DB table)? | Config & drift detection |
