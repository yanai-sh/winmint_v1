# ADR-011: WinMint v2 greenfield rewrite

**Status:** Accepted  
**Date:** 2026-07-18  
**Updated:** 2026-07-27 — grill outcomes: guest pwsh-free Supervisor ([seed ADR-004](../v2/seed-for-new-repo/docs/decisions/ADR-004-stack-and-guest-control-plane.md))  
**Supersedes (for the v2 project only):** [ADR-001](ADR-001-gpui-to-webview2-wizard.md) WebView2 wizard; [ADR-008](ADR-008-profile-schema-v4.md) as the v2 profile contract  
**Revises (for the v2 project only):** [ADR-002](ADR-002-dual-setup-shell-hosts.md) (Avalonia wizard later on host; in-process splash in guest Supervisor); [ADR-003](ADR-003-powershell-engine-boundary.md) (pwsh = host Servicing only; guest is C#)  
**Does not change:** this repository’s v1 code until cutover; [ADR-005](ADR-005-user-iso-truth.md) / [ADR-010](ADR-010-source-iso-legal.md); [ADR-006](ADR-006-dma-interop.md) intent for smoke

### Context

v2 is a new clean GitHub repository with no v1 profile/CLI back-compat. Prefer elegant modern solutions over v1 or early-v2 precedent. Guest/runtime reliability is the primary design pressure; Smoke and bare metal share product standards when possible.

### Decision

1. **New repo**, pre-planned commit history; this repo remains v1 until bootstrap/docs cut over.
2. **Orchestrator-first:** typed C# (`net11.0`, SDK pinned) owns Profile validation, planning, CLI; unelevated by default.
3. **Elevated PowerShell** = thin **host Servicing** kernels only — not guest FirstLogon.
4. **C# CLI** is the only product headless surface (tiny download bootstrap script OK).
5. **Guest:** one Native AOT **Provisioning Supervisor** (`--machine-setup` + Winlogon Shell), in-process splash, DMA settle (hard locale/GeoID/TZ, soft location), C# child-process provisioning jobs, in-memory status + evidence snapshots, Shell-tenure lock, checkpoint reboot. **No guest pwsh.**
6. **Clean-sheet JSON contracts** — no v1 BuildProfile/InstallPlan migration target.
7. **Avalonia 12.1.x** later for **host** wizard only — never on the ISO.
8. **First vertical = Smoke:** Profile → ISO → Hyper-V unattend → FirstLogon with splash + DMA hard-field evidence; plumbing only; password-required local account; Hyper-V smoke SKU = **Pro**.
9. **CLI-first Smoke** — Avalonia after the path is green.
10. **Image quality lanes:** test/Smoke = fast; release = `Max` + cleanup. Run override, not Profile. ISO fingerprint cache / checkpoint / push-only remain VM harness concerns.
11. **Microsoft-thin NuGet** — see seed [STACK.md](../v2/seed-for-new-repo/docs/STACK.md).

### Consequences

- This repository is the **v1 archive/reference** (`yanai-sh/winmint_v1`). Active greenfield work is [`yanai-sh/winmint`](https://github.com/yanai-sh/winmint). Do not rewrite v1 in place under this ADR.
- Seed/planning docs remain at [`docs/v2/seed-for-new-repo/`](../v2/seed-for-new-repo/) for archaeology; the live v2 tree may diverge (leaner day-one scaffold).
- Greenfield C# does not shorten DISM-bound ISO builds.

### Review trigger

Smoke Hyper-V gate fails to converge; legal/SDK (net11 GA) forces TFM change; or seed ADR-004 review triggers fire.
