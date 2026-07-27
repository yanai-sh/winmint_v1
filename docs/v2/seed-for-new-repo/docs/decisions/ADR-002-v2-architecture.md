# ADR-002: Greenfield architecture and Smoke-first delivery

**Status:** Accepted  
**Date:** 2026-07-18  
**Updated:** 2026-07-27 — guest control plane per [ADR-004](ADR-004-stack-and-guest-control-plane.md) (grill)

### Context

WinMint v2 is a new repository with no v1 contract back-compat. Empirical pain is guest/runtime reliability. Prefer elegant modern solutions over prior intent when they conflict. Smoke and bare metal should share product standards (settle, executor, reboot, lock) when possible.

### Decision

1. **Orchestrator-first:** typed C# (`net11.0`, SDK pinned) owns Profile validation, planning, and the public **C# CLI**; unelevated by default.
2. **Elevated PowerShell** runs thin **host Servicing** kernels only — not guest FirstLogon, not a v1 `WinMint.ps1` subprocess.
3. **Clean-sheet JSON contracts** — no migration target for v1 BuildProfile / InstallPlan.
4. **Dual hosts (authoring vs ISO):** Avalonia wizard later on the **build host**; ISO guest UI is the Provisioning Supervisor’s in-process splash — not Avalonia.
5. **Guest control plane (ADR-004):** one Native AOT Provisioning Supervisor (`--machine-setup` + Winlogon Shell); DMA settle; C# provisioning jobs; in-memory status + evidence snapshots; Shell-tenure lock; checkpoint reboot.
6. **First vertical = Smoke:** Profile → ISO → Hyper-V unattend → FirstLogon with splash + DMA hard-field evidence ([ADR-003](ADR-003-dma-interop.md)); plumbing only; password-required local account; Hyper-V smoke SKU = Pro.
7. **CLI-first Smoke** — wizard after the path is green.
8. **Pre-planned git history** via `/to-spec` → `/to-tickets` → `/implement` (see [WORKFLOW.md](../WORKFLOW.md)).
9. **Image quality lanes** (run override, not Profile): test/Smoke fast; release `Max` + cleanup. See [ARCHITECTURE.md](../ARCHITECTURE.md#image-quality-run-override-not-profile).

### Consequences

- Debloat, BitLocker policy, Avalonia, hard input lockdown, and hardware acceptance are later verticals.
- Do not expect C# orchestration to shorten DISM-bound ISO builds.
- Do not reintroduce guest pwsh or peer Splash.exe as Shell.

### Review trigger

Smoke Hyper-V gate fails to converge; net11 GA forces TFM change; or ADR-004 review triggers fire.
