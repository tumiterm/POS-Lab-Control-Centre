# POS Lab Control Centre — Refined Requirements

> Status: **Draft v0.2** — refined from the original requirement through discussion.
> Open questions are tracked in [open-questions.md](open-questions.md).

## 1. Problem

POS developers and testers remote into dev/test lab machines to test the WPF POS
application and its supporting components. Today:

- You cannot see **who is on a lab** before connecting. On a single-session machine,
  connecting silently kicks the current user off.
- You cannot see **whether a lab is fit to test on**. POS components are released
  independently (POS, Store Services, Store Master Data, Store Enterprise Library,
  Store Management, …). A lab can have the right POS build while a supporting
  component failed to deploy or was never released — testers then test on a
  **partly right** version without knowing it.
- **Master Data Distribution (MDD)** can look fine (service running) while no Head
  Office data is actually arriving.

## 2. Primary question the product answers

> **Which lab can I safely use right now, and is it technically ready for the test I want to perform?**
> — answered *before* opening an RDP session.

## 3. Key concepts

| Concept | Meaning |
|---|---|
| **Lab** | A registered POS lab machine (e.g. `Sandbox (456112)`, `TST Latest (020318)`). |
| **Occupancy** | Whether someone holds an RDP session on the lab right now (agent-detected fact). |
| **Reservation** | A time-boxed claim on a lab by a person (user intent). Separate from occupancy. |
| **Component** | An independently released POS part (POS, Store Services, …). |
| **Installed version** | What the agent finds on the lab. **Source of truth.** |
| **Latest released version** | Latest successful build/release of a component in TFS. |
| **Deployed-by-TFS version** | Last successful TFS deployment to the stage linked to this lab (optional link). |
| **Prod baseline** | The versions on the `Compatible (030310)` lab, which mirrors production and is normally left untouched. Gives a **before (prod) vs after (new)** comparison. |
| **Build coherence** | Components share build numbers (`YY.MM.DDrr`, e.g. `26.10.0201`). A lab with POS on one build and Store Services on an older one has **mixed builds**. |
| **Snapshot** | The full set of installed component versions at a point in time; created only when something changes. |
| **Readiness** | A list of named pass/warn/fail checks — never a percentage score. |

## 4. Functional requirements

Priority: **M** = must (MVP), **S** = should (soon after), **C** = could (later).

### 4.1 Lab register — M
- Store per lab: machine name, display name, TFS stage name (optional), environment
  (DEV/TST/TRN/PRD-like), classification (dev/test/prod-baseline), country, branch,
  store, network identifier, free-form extra properties (key/value).
- Expected configuration (country, branch, store, required services, required
  components) is stored centrally to enable drift detection.
- Filter by environment, country, branch, availability, health.
- The `Compatible (030310)` lab is flagged as **prod baseline**.

### 4.2 Occupancy (RDP sessions) — M
- Agent reports sessions: user (`TFG\username`), state (Active / Disconnected),
  logon time, idle time.
- Lab availability is one of: **Available**, **Occupied**, **Disconnected session**
  (someone still holds it), **Maintenance**, **Agent unreachable**, **Offline**.
- Display: current user, session state, duration.

### 4.3 Reservations — M (early)
- Fields: user, lab, start, expiry, purpose, optional work item (US/Bug id).
- Auto-expire; may be extended; max length configurable.
- **Advisory** (warns, does not block RDP) in v1.
- **Reservation conflict** shown when the RDP user differs from the reservation owner.

### 4.4 Component versions & alignment — M
- Agent reports installed version per component (how it is read is decided in Phase 0).
- Per component, statuses:
  - **Current** — installed = latest released
  - **Behind** — newer release exists
  - **Mixed build** — older build than the lab's POS build
  - **Drift** — installed ≠ what TFS says it deployed to this lab's stage (when linked)
  - **Unknown** — cannot be determined
- **Prod comparison**: any lab can be compared against the prod baseline lab
  (`Compatible (030310)`) to show what is new vs production.
- Optional per-environment **pinned expected version** (off by default).

### 4.5 TFS integration (read-only, shallow) — S
- Per release definition (one per component): latest successful build, latest
  release, and its per-stage status.
- Optional lab → stage link to get "last deployed to this lab".
- We deliberately **do not** model full release pipelines.

### 4.6 Windows services — M (view), C (actions)
- Configurable list of required services per lab/environment.
- Show name, state, start type, last state change.
- **Actions (later):** start/stop/restart on an allow-list only, by authorised roles,
  executed by the agent, fully audited. No arbitrary commands/PowerShell.

### 4.7 MDD health — M (basic), S (diagnostics)
- Status: **Healthy / Warning / Critical / Unknown**, with a human-readable reason.
- Must use evidence of actual synchronisation (last import, last data received,
  backlog, recent errors), not just service state.
- Thresholds configurable. Exact signals decided in Phase 0 discovery of
  `C:\Program Files\TFG\SQL\Change Tracking Queue Import Services`.
- Recovery actions only after common failure modes are understood.

### 4.8 Readiness — S
- Checks: available, not in maintenance, agent healthy, POS current, no mixed
  builds, components current/expected, MDD healthy, required services running,
  configuration matches expected.
- Overall: **Ready / Ready with warnings / Not ready**, always listing failing checks.

### 4.9 Find me a lab — S
- Criteria: environment, country, branch, availability, MDD, version state.
- Excludes labs in maintenance; ranks Ready first.
- Actions from result: Reserve, Connect.

### 4.10 Snapshots & history — S
- Snapshot on version change; numbered (e.g. *Snapshot #1842*).
- Event history: connect/disconnect, reservation created/expired, service state
  change, MDD state change, component updated, online/offline, config change.
- "Changes since my last session" (C).

### 4.11 Connect — S
- Downloads a generated `.rdp` file for the lab.
- Confirmation shown if occupied / reserved by someone else.

### 4.12 Maintenance mode — S
- Admin sets reason and expected return; lab excluded from Find me a lab.

### 4.13 Later (C)
- Lab comparison side-by-side; configuration drift report; post-deployment health
  check; work item awareness (US/Bug → required versions); availability
  notifications; machine health (uptime, CPU, memory, disk, pending reboot).

## 5. Non-functional requirements

- **Security:** AD-authenticated users; roles Viewer / QA / Developer / Admin; agent
  authenticates with a per-machine key (or certificate); no credentials in browser;
  every state-changing action audited (user, lab, action, before/after, result).
- **Agent:** lightweight Windows service; outbound HTTPS only; executes only
  predefined commands; heartbeat every 30–60s (configurable).
- **Offline detection:** missed heartbeats → *Agent unreachable*; distinguish from
  "machine unreachable" where possible.
- **Freshness:** dashboard reflects agent data within ~1 minute.
- **Scale:** tens of labs (design for ~100).

## 6. Delivery phases

| Phase | Scope |
|---|---|
| **0. Discovery** | Run `discovery/Invoke-LabDiscovery.ps1` on one lab (+ the prod baseline lab). Decide how to read versions, config, MDD health. |
| **1. MVP** | Agent + API + dashboard: occupancy, heartbeat, installed versions, mixed-build check, services view, lab register. Several labs from day one. |
| **2. Reservations** | Reserve/extend/expire, conflicts, `.rdp` connect. |
| **3. TFS + prod compare** | Latest released, behind status, compare to `Compatible (030310)`. |
| **4. MDD** | Health statuses + diagnostics. |
| **5. Readiness + Find me a lab + history/snapshots** | |
| **6. Actions** | Allow-listed service restarts, maintenance mode, audit UI. |
| **7. Later** | Work items, notifications, drift, post-deploy checks. |

## 7. Success criteria

One application answers: which labs are free · who is on a lab · which lab fits my
environment/country/branch · what versions are installed · is anything on a mixed or
old build · what differs from prod · is MDD receiving data · are required services
running · is the lab ready, and if not, why · what changed recently.
