# WinMint v2 architecture (locked)

Greenfield project: **new GitHub repository**, no backwards compatibility with WinMint v1 contracts or CLI. See [ADR-002](decisions/ADR-002-v2-architecture.md), [ADR-004](decisions/ADR-004-stack-and-guest-control-plane.md). Full stack inventory: [STACK.md](STACK.md). Naming: [NAMING.md](NAMING.md). Tree: [STRUCTURE.md](STRUCTURE.md). Glossary: [CONTEXT.md](../CONTEXT.md).

**Design stance:** prefer modern elegant solutions over v1/v2 precedent when they conflict. Smoke and bare metal share the same Supervisor / settle / job executor / reboot / lock rules; they may differ in Profile job set and acceptance evidence bars only.

## Architectural style

**Use: pipeline orchestrator + ports & adapters** (hexagonal at one hard seam).

| Idea | How it shows up here |
|------|----------------------|
| **Pipeline / orchestrator** | Unelevated C# sequences validate → plan → emit job/unattend → invoke Servicing → collect evidence |
| **Port** | “Run elevated imaging job” / “stage payload tree” — small interfaces the Orchestrator owns |
| **Adapter** | Thin `pwsh -File` kernels under `servicing/` (DISM, hive, oscdimg); filesystem staging |
| **Deep modules** | Fat behaviour behind small surfaces (e.g. `IServicingRunner`, Profile validator, Supervisor settle/jobs) |

**Do not use as the backbone:** Clean Architecture onion, full tactical DDD, or microservices — batch imaging pipeline, one process graph + elevated Servicing helper.

**Bounded contexts (strategic only):**

| Context | Owns | Folder gravity |
|---------|------|----------------|
| **Authoring** | Profile intent, CLI, later Wizard | `src/WinMint.Cli`, `src/WinMint.Wizard`, Orchestrator Config |
| **Imaging** | Plan, unattend, Servicing jobs | `src/WinMint.Orchestrator`, `servicing/` |
| **Provisioning** | Supervisor (Machine setup + Shell + jobs), staged media | `src/WinMint.Provisioning`, `payload/` |

Cross-context rule: Imaging must not call live Provisioning APIs; it only **stages** files. Provisioning never mounts WIMs.

## Runtime shape

```
Unelevated C# CLI / Orchestrator  →  elevated pwsh Servicing adapters
                                 →  stages Provisioning binary; stamps Shell offline
Avalonia wizard (later)          →  same Orchestrator ports

Guest:
  SetupComplete.cmd → Provisioning --machine-setup
  Winlogon Shell = same AOT binary
    → in-process splash → DMA settle → provisioning jobs
    → complete/failed/timeout → explorer.exe
    → reboot → checkpoint, keep Shell, resume
```

| Layer | Owns | Must not own |
|-------|------|----------------|
| **Orchestrator** (C#) | Profile validation, plan, CLI, unattend/job JSON | In-process DISM / offline hive |
| **Servicing** (elevated `pwsh -File`) | Thin DISM/WIM/hive/export adapters | Product CLI, fat monolith, guest FirstLogon |
| **Provisioning Supervisor** (C# AOT) | Machine setup stamps, Shell tenure, splash, DMA settle, jobs, evidence snapshots, unlock | Offline imaging |
| **Wizard** (Avalonia, later) | Profile authoring UI | Servicing, ISO splash |

## First vertical: Smoke

- Profile → ISO → Hyper-V unattend install → FirstLogon complete
- Evidence: splash plumbing + DMA **hard**-field settle (+ optional status snapshots)
- Plumbing only: no debloat/keep matrix, no BitLocker policy
- Password-**required** local account; Hyper-V smoke SKU = **Pro**
- **CLI-first** — Avalonia after Smoke is green
- User always supplies official Microsoft **Source ISO** ([ADR-001](decisions/ADR-001-source-iso-legal.md))
- Fast image-quality lane for Smoke builds
- **Guest pwsh-free**; Supervisor is Shell ([ADR-004](decisions/ADR-004-stack-and-guest-control-plane.md))

### Machine setup + Autologon / Shell invariants

Before first interactive logon:

1. Servicing stamps Winlogon Shell (DefaultUser / as designed) to the Supervisor path offline.
2. Machine setup (`Provisioning --machine-setup` from SetupComplete.cmd): stamp profile autologon **before** any long work; fail-closed verify/restamp Shell; secret wipe as required. **No** provisioning jobs here.
3. Never leave `DefaultUserName=defaultuser0` with `AutoAdminLogon` for the first interactive logon.

### Shell tenure (provisioning lock)

While Supervisor is Winlogon Shell and showing splash, the session is under provisioning lock. Unlock = set Shell to `explorer.exe` and exit. Hard input/task-switch policy is later hardening, not Smoke-critical.

**Fail-open:** unlock on `complete` / `failed` (after a short failed dwell so status is readable) and on hard wall-clock timeout (treated as `failed`). Phase `reboot` **keeps** Supervisor as Shell for resume.

### DMA settle

Same policy on Smoke and bare metal:

1. Restore visible region after Ireland Setup.
2. Bounded poll, then **one final snapshot**.
3. Locale / GeoID / time zone must match Profile → else phase `failed`, no jobs.
4. Location-services posture is soft (warn, continue).

### Splash and theme

- Splash is **in-process**; paints its own dark/branded canvas (no system-theme dependency).
- Before unlock to Explorer, apply Profile appearance once.
- No mid-provision theme hard-gate.

### Provisioning status

In-memory model drives the presenter. JSON snapshots are **evidence/observability** for harness pulls — not the control-plane mailbox.

### Provisioning jobs + reboot

- Supervisor runs `winget` / Scoop / `wsl` (etc.) as **child processes**.
- Smoke vs metal differ in **which jobs** the Profile schedules, not in the executor.
- On `needsReboot`: persist checkpoint, phase `reboot`, keep Shell, reboot; after auth resume under splash.

### Splash presentation model

| Concern | Behaviour |
|---------|-----------|
| Host | Direct2D with GDI fallback, in-process |
| Control phases | `running` → `finishing` → `complete` / `failed` / `reboot` |
| Paint cues | OOBE-style stages, detail, `i of n`, thin bar — no `%`, no package-manager names |
| Accessibility | Reduced motion, high-contrast flat canvas, Narrator-friendly title updates |

Clean-sheet status schema; v1 splash behaviour is reference only when useful.

## Image quality (run override, not Profile)

ISO wall-clock is dominated by DISM + WIM export. Keep two lanes:

| Lane | Export / cleanup | Use |
|------|------------------|-----|
| **Test / Smoke** | Soft or no recompress; **skip** WinSxS `StartComponentCleanup` | Iteration, Hyper-V Smoke |
| **Release** | Hard recompress (`Max`) + `StartComponentCleanup` | Published / bare-metal ISOs |

Manifest/report must record what ran. VM SmartBuild / checkpoint / push-only remain harness concerns.

## Payload strategy

Stage media, SetupComplete.cmd, Supervisor binary, and job manifests. Behaviour ideas may be harvested from v1; **implementation** is C# Supervisor + thin host Servicing. Do not wrap v1 `WinMint.ps1`. Do not stage guest pwsh as FirstLogon runtime.

## Post-Smoke product stances (harvest, not Smoke scope)

When product depth lands after Smoke, carry forward only where still desired: Edge stays installed (noise debloat only), Home-first quiet UX, Coreutils baseline, managed `wsl.conf`, no Raycast/Everything, `PreventDeviceMetadataFromNetwork` with WU drivers preserved. See [PORT-FROM-V1.md](PORT-FROM-V1.md).

## Stack (summary)

See [STACK.md](STACK.md).

- Guest: **C# only** (one AOT Provisioning exe)
- Host Servicing: **pwsh 7.6+** thin kernels
- `net11.0` + Native AOT; NuGet Microsoft-thin; Avalonia 12.1.x later for host wizard only
