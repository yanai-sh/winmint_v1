# WinMint — Agent contract

Windows 11 ISO builder (greenfield v2). Host is Windows; use native arm64 toolchains when on ARM. Elevated **host Servicing** needs **pwsh 7.6+**. Guest FirstLogon is **C# only** (no staged pwsh).

`AGENTS.md` is the compact contract for coding agents. New clone / seed zip → [`docs/START.md`](docs/START.md). Product pitch → [`README.md`](README.md). Glossary → [`CONTEXT.md`](CONTEXT.md). Architecture → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Stack → [`docs/STACK.md`](docs/STACK.md). Naming → [`docs/NAMING.md`](docs/NAMING.md). Tree → [`docs/STRUCTURE.md`](docs/STRUCTURE.md). Tooling → [`docs/TOOLING.md`](docs/TOOLING.md) + root [`Justfile`](Justfile). Process → [`docs/WORKFLOW.md`](docs/WORKFLOW.md). AOT/C# → [`docs/coding-contract.md`](docs/coding-contract.md). Decisions → [`docs/decisions/`](docs/decisions/). Tracker → [`docs/agents/`](docs/agents/). Content → [`assets/`](assets/README.md), [`payload/`](payload/README.md). Harvest map → [`docs/PORT-FROM-V1.md`](docs/PORT-FROM-V1.md) (v1 optional; behaviour reference only).

## Core rule

**CLI/Orchestrator creates and executes intent. Servicing mutates the offline image. Provisioning Supervisor finishes live-user setup. Reports explain work.**

```
Bootstrap (optional) → C# CLI / Orchestrator → elevated pwsh Servicing
  → Windows Setup → SetupComplete.cmd → Provisioning --machine-setup
  → Winlogon Shell = same Provisioning AOT binary
  → splash + DMA settle → provisioning jobs → explorer (fail-open)
```

Unelevated C# owns Profile validation, planning, unattend/job JSON, and the public CLI. Elevate **only** Servicing `pwsh -File` jobs. Do not run DISM/hive in-process in the CLI or wizard. Do not wrap v1 `WinMint.ps1`. Do not stage guest pwsh for FirstLogon.

## Boundaries

| Layer | Owns | Must not own |
|-------|------|----------------|
| Orchestrator (C#) | Profile, plan, CLI, job JSON | In-process DISM / offline hive |
| Servicing (elevated pwsh) | Thin mount/stage/hive/export kernels | Product CLI, fat monolith, guest FirstLogon |
| Provisioning Supervisor (C# AOT) | Machine setup, Shell tenure, splash, DMA settle, jobs, evidence snapshots, unlock | Offline imaging |
| Wizard (Avalonia, later) | Profile authoring UI | Servicing, ISO splash |
| Reports | Manifest / evidence / human summaries | Business decisions |

## Product stance (Smoke era)

- **Source ISO is legally user-supplied** ([ADR-001](docs/decisions/ADR-001-source-iso-legal.md)).
- **Clean-sheet contracts** — no v1 BuildProfile / InstallPlan / PowerShell CLI back-compat.
- **C# CLI only** — tiny download bootstrap script OK.
- **Guest pwsh-free; host Servicing pwsh 7.6+** ([ADR-004](docs/decisions/ADR-004-stack-and-guest-control-plane.md), [STACK.md](docs/STACK.md)).
- **DMA default-on** — Ireland/`en-IE` during Setup; Supervisor DMA settle before jobs ([ADR-003](docs/decisions/ADR-003-dma-interop.md)). Hard locale/GeoID/TZ; soft location; same Smoke and metal.
- **Local accounts require a password** for unattended Smoke.
- **Machine setup** — autologon + Shell verify/restamp only; never `defaultuser0` + AutoAdminLogon ([ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Supervisor as Shell** — in-process splash; Shell-tenure lock; checkpoint reboot; fail-open on complete/failed/timeout.
- **No maintenance payload** on the installed system.
- **Hyper-V Smoke SKU = Pro**; product default SKU may stay Home later.
- **Out of Smoke / not early:** Avalonia wizard, debloat/keep matrix, BitLocker, hard input lockdown, hardware acceptance. Harvest map: [PORT-FROM-V1.md](docs/PORT-FROM-V1.md).
- **Image quality lanes** — test/Smoke fast; release Max + cleanup. Run override, not Profile.

## Delivery workflow

1. `/setup-matt-pocock-skills` (once per repo)
2. `/to-spec` (Smoke only) → `/to-tickets` (approve blockers)
3. `/implement` **one ticket per session**; TDD → review → commit when asked
4. Skip `/wayfinder` unless Smoke is blocked by fog

Details: [`docs/WORKFLOW.md`](docs/WORKFLOW.md).

## Stack

- `net11.0` + SDK pin; Native AOT on Cli + Provisioning; source-gen JSON; `LibraryImport`
- NuGet Microsoft-thin; Avalonia **12.1.x** later for host wizard only — [STACK.md](docs/STACK.md)
- Host Servicing: thin **pwsh 7.6+** — guest is C# only ([ADR-004](docs/decisions/ADR-004-stack-and-guest-control-plane.md))

## Commands

```powershell
winget install Casey.Just   # once
just                        # list
just check                  # format-check + build + test + analyze-ps
just sdk                    # confirm global.json pin
```

See [`docs/TOOLING.md`](docs/TOOLING.md).

## Domain docs

- Glossary: [`CONTEXT.md`](CONTEXT.md) — use those terms; [`docs/agents/domain.md`](docs/agents/domain.md)
- Hard decisions → `docs/decisions/`; don’t silently contradict Accepted ADRs

## Commit style

Conventional commits: `feat(scope):`, `fix(scope):`, `docs:`, etc. Scope = `orchestrator`, `servicing`, `provisioning`, `payload`, `cli`, …. Prefer one ticket → one intentional commit.
