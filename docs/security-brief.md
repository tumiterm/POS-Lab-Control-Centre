# Security Brief: POS Lab Monitoring Agent (draft for Cybersecurity)

## Purpose
POS developers and QA need to see, before connecting to a dev/test lab machine, whether
someone is already using it and whether its POS components and Master Data are in a
testable state. Today this needs a remote-desktop session, which disconnects the current
user on single-session machines.

## Scope
- **Machines:** POS **development and test lab machines only**. No production stores and no
  user laptops.
- **Data collected (read-only):**
  - Logged-on RDP user name and session state
  - Installed versions of POS components
  - State of an approved list of Windows services
  - Master Data Distribution status (timestamps, counts and error messages from its logs or DB)
  - Lab configuration values (country, branch, store)
  - Basic health: uptime, disk space, pending reboot
- **Not collected:** keystrokes, screen content, files, customer or cardholder data, or credentials.

## Design controls

| Control | Detail |
|---|---|
| Compiled, signed binary | .NET Windows service, signed with the organisation's code-signing certificate. No PowerShell scripts, so it needs **no execution-policy change**. |
| Outbound only | The agent makes HTTPS calls to one internal endpoint. No listening ports on the lab. |
| No remote execution | No arbitrary commands or scripts. Phase 1 is **read-only**. Any later action (e.g. restarting an approved service) is a fixed, allow-listed operation, enabled only by separate approval. |
| Least privilege | Runs as a dedicated low-privilege service account. Elevated rights are added only if a specific later feature needs them and is approved. |
| Authentication | Per-machine key or client certificate, rotatable. Users sign in to the web app with AD; access is role-based. |
| Audit | Every state-changing action in the web app is logged: who, what, when, before/after, result. |
| Deployment | Through an existing approved channel, e.g. the TFS release pipeline already used for POS components, or SCCM. Removable the same way. |
| Data retention | Status history kept N days (configurable). |

## Rollout
1. A read-only pilot on **one dev lab**.
2. Review the pilot with Cybersecurity.
3. Extend to the other dev/test labs.
4. Any action capability (service restart) requires a separate approval.

## Asks of Cybersecurity
1. Approval for a read-only pilot on one dev lab.
2. Access to code signing for the agent binary, or the approved way to deploy internal tools.
3. Guidance on the service account and network path from lab to the internal web server.
