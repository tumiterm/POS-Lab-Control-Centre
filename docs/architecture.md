# Architecture (proposed)

> Draft — to be confirmed once [open questions](open-questions.md) are answered.

```
 ┌────────────────────────┐   HTTPS (outbound only)    ┌──────────────────────────────┐
 │ Lab agent              │ ─── status / heartbeat ──▶ │ Central API (ASP.NET Core)   │
 │ (.NET Windows Service) │ ◀── pull approved cmds ─── │  ├─ Lab register & config    │
 │  • sessions (WTS)      │                            │  ├─ Status ingest            │
 │  • installed versions  │                            │  ├─ Reservations             │
 │  • services            │                            │  ├─ Readiness rules          │
 │  • MDD signals         │                            │  ├─ TFS poller (read-only)   │
 │  • lab config          │                            │  └─ Audit                    │
 └────────────────────────┘                            └──────┬──────────────┬────────┘
                                                              │              │
                                                     SQL Server         TFS REST API
                                                              │        (_apis/build,
                                                     Web UI (Blazor)    _apis/release)
                                                     + SignalR live updates
                                                     AD / Windows auth
```

## Decisions (proposed)

| # | Decision | Why |
|---|---|---|
| D1 | **.NET 8** for agent, API and UI (Blazor) | Team already writes C#/WPF; one language end to end. |
| D2 | **Agent pushes, and pulls commands** | Server needs no inbound admin rights on labs; works through firewalls. |
| D3 | **Installed version is the source of truth**; TFS is reference only | A TFS release existing ≠ installed; failed/partial deployments are common. |
| D4 | **Shallow TFS** — one call per component release definition; optional lab→stage link | Release pipelines have many stages; modelling them fully is not worth it. |
| D5 | **Prod baseline = `Compatible (030310)` lab** | It mirrors production and is rarely changed; gives before/after for free. |
| D6 | **Snapshots on change only** | Keeps snapshot numbers meaningful and storage small. |
| D7 | **Readiness = named checks**, no score | Users must always see *why* a lab isn't ready. |
| D8 | **Reservations advisory in v1** | Cheap, no agent enforcement; revisit if ignored. |
| D9 | **Allow-listed actions only**, audited | No arbitrary remote execution. |

## Agent payload (draft)

```json
{
  "machine": "TSTPOS020318",
  "agentVersion": "0.1.0",
  "timestampUtc": "2026-10-02T06:40:00Z",
  "sessions": [{ "user": "TFG\\jdoe", "state": "Active", "logonUtc": "...", "idleMinutes": 3 }],
  "components": [{ "name": "POS", "version": "26.10.0201", "source": "file:C:\\...\\POS.exe" }],
  "services": [{ "name": "...", "state": "Running", "startType": "Automatic" }],
  "mdd": { "lastImportUtc": "...", "lastDataReceivedUtc": "...", "backlog": 0, "recentErrors": [] },
  "config": { "country": "ZA", "branch": "540", "store": "..." },
  "machineHealth": { "uptimeMinutes": 1234, "diskFreeGb": 40, "pendingReboot": false }
}
```

## Version handling

Build numbers look like `YY.MM.DDrr` (e.g. `26.10.0201` = 2026‑10‑02, build 01).
Versions are compared numerically per segment. A component is a **mixed build**
when its version is older than the POS version installed on the same lab.

## Hosting (to confirm)

Internal Windows server (IIS or Kestrel as a Windows service), SQL Server database,
reachable from the lab network and from users on FortiClient.
