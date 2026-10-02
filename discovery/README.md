# Phase 0 — Lab Discovery

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
