# Open Questions & Answers

## Answered

| Question | Answer |
|---|---|
| Where do versions come from? | TFS classic Release pipelines on TFVC (`$/POS`); one release definition per component (POS, Store Services, Store Master Data, Store Enterprise Library, Store Management, SM CustomerPortal, …). |
| Why is "partly right" a problem? | Components are released independently; a lab can get a new POS while e.g. Store Services failed or wasn't released. |
| What are release stages? | A mix of purposes (DB deployments, UI automation, SCCM copy) and **lab machines** — the numbers in stage names (e.g. `Sandbox (456112)`, `TST Latest (020318)`) identify labs. There are many. |
| Is there a production reference? | `Compatible (030310)` holds what is in production and is normally not changed → use it as the **prod baseline** for before/after comparisons. |
| How deep should TFS integration go? | Shallow. Don't model the release processes. |

## Open

1. **Lab OS** — Windows 10/11 (single interactive session) or Windows Server (multi-session)?
2. **Agent install** — can a small Windows service be installed on one dev lab for the PoC? Any approval needed?
3. **Hosting** — where will the central app run? Is SQL Server available?
4. **Stack** — OK with .NET 8 (ASP.NET Core + Blazor) + SQL Server?
5. **Installed versions** — where is each component's version visible on a lab (Add/Remove Programs, exe file version, config)? *Phase 0 script will help.*
6. **Version format** — confirm `YY.MM.DDrr` and that installed version equals the TFS build number.
7. **Lab config** — where do country/branch/store live on the lab (config file, registry, DB)? *Phase 0.*
8. **MDD** — logs? last-processed marker in the local DB? how is failure noticed today? *Phase 0.*
9. **TFS access** — TFS/Azure DevOps Server version; read-only PAT with Build (read) + Release (read)?
10. **Release lines** — do Development / Main / Main-UAT / Dev1.1 map to particular labs?
11. **Deployment Groups** — are labs registered there (could seed the lab register)?
12. **Audience & approval** — first users; who signs off on service-restart capability?
