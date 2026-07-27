# ADR-004: Product stack and guest control plane

**Status:** Accepted  
**Date:** 2026-07-27  
**Updated:** 2026-07-27 — grill: guest pwsh-free, in-memory status, C# provisioning jobs  
**Revises:** [ADR-002](ADR-002-v2-architecture.md)  
**Companion:** [STACK.md](../STACK.md), [ARCHITECTURE.md](../ARCHITECTURE.md), [CONTEXT.md](../../CONTEXT.md)

### Context

Guest/runtime reliability (Shell-before-Explorer, DMA settle races, splash timing) dominates real Smoke pain. Host Profile typing alone does not fix that. A hybrid PowerShell FirstLogon control plane reintroduces pwsh cold start on the critical path. Precedent from v1 or earlier v2 drafts is not authority when a simpler design wins.

### Decision

1. **Product languages:** C# for CLI, Orchestrator, and **all guest FirstLogon/Machine setup**. PowerShell 7.6+ for **host Servicing kernels only**. No Rust/Go/C++/Python/Node in product runtime. No staged guest pwsh requirement.
2. **Host:** Unelevated C# Orchestrator/CLI; elevated thin `pwsh -File` Servicing (DISM/WIM/hive/oscdimg). No wrapping v1 `WinMint.ps1`.
3. **One guest AOT binary (Provisioning Supervisor):** Winlogon Shell after auth; `--machine-setup` from SetupComplete.cmd for stamp-only Machine setup. In-process Direct2D/GDI splash (no peer Splash.exe).
4. **Shell registration:** Servicing stamps Shell offline; Machine setup fail-closed verifies/restamps (same posture as autologon stamp).
5. **DMA settle:** Final snapshot after bounded restore. Hard: locale, GeoID, time zone. Soft: location posture. **Same policy** on Hyper-V Smoke and bare metal.
6. **Provisioning jobs:** Supervisor runs winget/Scoop/wsl (etc.) as child processes. Smoke vs metal differ in job *set*, not executor.
7. **Status:** In-memory for paint; JSON snapshots for evidence only.
8. **Fail-open:** Unlock Shell on `complete`/`failed` (+ failed dwell) and wall-clock timeout; hold Shell on `reboot` with durable checkpoint resume.
9. **Theme:** Splash-owned canvas; apply Profile appearance once before Explorer unlock — no theme hard-gate.
10. **Provisioning lock:** Shell tenure while Supervisor is Shell; hard input lockdown is later hardening.
11. **NuGet:** Microsoft-thin (source-gen JSON, `System.CommandLine`, xUnit; Avalonia 12.1.x later for host wizard). Every package needs “why not BCL.”
12. **Rejected for day-one:** guest pwsh adapters, file-as-control-plane status, C#-only in-process DISM as default, separate Splash.exe peer, Hyper-V-only settle/executor forks.

### Consequences

- Smoke tickets prioritize Supervisor modes (machine-setup + Shell) over harvesting PreLock.ps1 / agent modules as session entrypoints.
- PORT-FROM-V1 maps v1 behaviour into C# Supervisor APIs; scripts are archaeology.
- Host build wall-clock remains DISM-bound; keep image-quality lanes and VM harness caching.

### Review trigger

Supervisor AOT cold start still loses to Explorer flash; or host `servicing/` becomes a second monolith justifying a C#-only DISM ADR; or a measured job proves C# child-process glue worse than a narrow script exception (then ADR a single helper — not a guest pwsh runtime).
