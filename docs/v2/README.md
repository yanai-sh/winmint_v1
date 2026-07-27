# WinMint v2 (planning archive in the v1 repo)

**Product development moved to [`yanai-sh/winmint`](https://github.com/yanai-sh/winmint).** This folder stays as the planning/seed archive that bootstrapped v2 — update it only when harvest notes or historical decisions need clarifying for archaeology.

| Path | Role |
|------|------|
| [`seed-for-new-repo/`](seed-for-new-repo/) | Historical seed tree (copied into the v2 repo). How it was copied: [`COPY-INTO-NEW-REPO.md`](COPY-INTO-NEW-REPO.md). |
| [`seed-for-new-repo/docs/STACK.md`](seed-for-new-repo/docs/STACK.md) | Locked product stack |
| [`seed-for-new-repo/docs/ARCHITECTURE.md`](seed-for-new-repo/docs/ARCHITECTURE.md) | Locked architecture |
| [`seed-for-new-repo/CONTEXT.md`](seed-for-new-repo/CONTEXT.md) | Ubiquitous language |
| [`roadmap.md`](roadmap.md) | Legacy living roadmap — prefer ADR-011 + the seed |
| [`coding-contract.md`](coding-contract.md) | Stub → seed coding contract |
| [`migration-guide.md`](migration-guide.md) | Stub → seed architecture / workflow |

**Accepted decisions in this repo:** [ADR-010](../decisions/ADR-010-source-iso-legal.md), [ADR-011](../decisions/ADR-011-winmint-v2-greenfield.md).

**Seed ADRs:** [001](seed-for-new-repo/docs/decisions/ADR-001-source-iso-legal.md)–[004](seed-for-new-repo/docs/decisions/ADR-004-stack-and-guest-control-plane.md).

**Do not** treat ADR-011 as a license to rewrite v1 in place.

## Stack summary (grill-locked 2026-07-27)

- **Host:** C# Orchestrator/CLI → thin elevated pwsh Servicing  
- **Guest:** one AOT Provisioning Supervisor (`--machine-setup` + Shell); in-process splash; **no guest pwsh**  
- **DMA settle:** final snapshot; hard locale/GeoID/TZ; soft location; same Smoke and metal  
- **Jobs:** C# child processes (winget/Scoop/wsl); Profile job set may differ by tier  
- **Lock:** Shell tenure; unlock on complete/failed/timeout; reboot keeps Shell + checkpoint  
- **Status:** in-memory paint; JSON snapshot = evidence only  
- **NuGet:** Microsoft-thin; Avalonia 12.1.x later for host wizard only  

## Keeping the seed honest

When durable product posture changes, update:

1. [`seed-for-new-repo/docs/PORT-FROM-V1.md`](seed-for-new-repo/docs/PORT-FROM-V1.md)  
2. [`ARCHITECTURE.md`](seed-for-new-repo/docs/ARCHITECTURE.md) + [`STACK.md`](seed-for-new-repo/docs/STACK.md) + [`AGENTS.md`](seed-for-new-repo/AGENTS.md) / [`CONTEXT.md`](seed-for-new-repo/CONTEXT.md)  
3. [`roadmap.md`](roadmap.md) only when it changes what v2 should steal or avoid  

**Last sync:** 2026-07-27 — grill-sharpened guest control plane (ADR-004); local Smoke spec + `.scratch/winmint-v2-smoke` tickets.
