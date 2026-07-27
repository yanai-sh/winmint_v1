# Port-from-v1 harvest map

WinMint v2 is a **new repo** with clean-sheet contracts. Do **not** submodule v1. Day-one scaffold stands alone — **v1 on disk is optional** until a Servicing or Supervisor-behaviour ticket needs a proven reference.

**Last harvest sync:** 2026-07-27 — grill-locked guest control plane ([ADR-004](decisions/ADR-004-stack-and-guest-control-plane.md)). This map is **behaviour archaeology**, not authority. Prefer elegant modern solutions when they conflict with v1.

## Locating v1 (when a ticket needs it)

```powershell
# sibling clone (recommended)
git clone https://github.com/yanai-sh/winmint_v1.git ..\winmint-v1
# paths in the tables below are relative to that clone's root
```

Or point at any existing local v1 checkout. Never copy the v1 tree into this repo.

**Deferred shell presets** (and placeholder picker icons) may live in the companion `winmint-v2-future-assets-*.zip` (or v1’s `docs/v2/future-assets/`). Avalonia / picker icons are **not** early v2 work.

Paths below are relative to the **v1** repo root unless noted.

## Imaging adapters → `servicing/` (host pwsh)

| Steal idea from (v1) | Land in v2 |
|----------------------|------------|
| DISM mount/save/dismount kernels | `servicing/Mount-Wim.ps1`, `Dismount-Wim.ps1` |
| ISO mount, oscdimg export pieces | `servicing/Mount-IsoStage.ps1`, `Export-Iso.ps1` |
| Offline registry tweak apply / `reg load` | `servicing/Apply-OfflineOps.ps1` |
| Payload copy via manifest (not hardcoded name lists) | `servicing/Stage-Payload.ps1` + `payload/payload-manifest.json` |
| Unattend / DMA locale merge | **Rewrite in C#** (`WinMint.Orchestrator` Unattend) |
| Entire `WinMint.ps1` load / ISO pipeline entry | **Do not wrap** |
| Image-quality lanes (`Max`/`Fast`/`None`, component cleanup) | Orchestrator run overrides + Servicing export kernels |
| SmartBuild fingerprint, VM checkpoint, push-only | `tools/vm/` harness only |
| `PreventDeviceMetadataFromNetwork` (+ WU drivers preserved) | Offline hive ops after Smoke plumbing |

## Provisioning → `WinMint.Provisioning` + `payload/`

v1 FirstLogon/lock/DMA/agent scripts are **behaviour references only**. Implementation is the **C# Provisioning Supervisor** (guest pwsh-free).

| Steal idea from (v1) | Land in v2 |
|----------------------|------------|
| DMA restore criteria (locale/GeoID/TZ/location soft) | Supervisor **DMA settle** — final snapshot; no sticky intermediate fails |
| Splash before Explorer | Supervisor as Winlogon Shell + in-process splash — **do not** port PreLock.ps1 as Shell |
| Transaction / step order | Supervisor state machine; clean-sheet phases |
| Shell override + fail-open | Supervisor unlock on complete/failed/timeout; hold Shell on reboot |
| Autologon stamp before long work; never `defaultuser0` + AutoAdminLogon | Supervisor `--machine-setup` from SetupComplete.cmd (+ offline Shell stamp in Servicing) |
| Status stages / a11y paint cues | In-memory provisioning status + optional evidence JSON snapshots |
| Direct2D/GDI splash | In-process presenter inside `WinMint.Provisioning` (not a peer exe) |
| `needsReboot` under lock | Checkpoint + keep Supervisor as Shell |
| winget / Scoop / WSL install sequencing | Supervisor **provisioning jobs** as child processes — not `payload/agent/*.ps1` |
| Pins / desktop finalize honesty | Post-Smoke job verticals |

## Post-Smoke product harvest (later verticals)

| Steal idea from (v1) | Land in v2 (later) |
|----------------------|--------------------|
| Edge stays; noise ADMX only; no uninstall UI | Profile/posture + offline Edge policy |
| Home quiet-UX | Offline + FirstLogon quiet posture |
| Microsoft.Coreutils via winget | Provisioning job baseline |
| Managed `wsl.conf` + default user | WSL job |
| Terminal profiles / Cascadia | `payload/media/terminal/` + jobs |
| Explorer QoL baselines | Offline tweak modules |
| Smoke profile matrix + mocked WSL | `tools/vm/` fixtures |

## Already in this seed (day one)

| Content | Location |
|---------|----------|
| .NET scaffold | `src/`, `tests/` |
| Brand | `assets/brand/` |
| Media | `payload/media/` |
| Servicing stubs | `servicing/` |
| Docs / ADRs | [`START.md`](START.md), [`ARCHITECTURE.md`](ARCHITECTURE.md), [`STACK.md`](STACK.md), [`decisions/`](decisions/) |

## Never port as authority

- v1 BuildProfile / InstallPlan schemas  
- WebView2 wizard / ui-bridge  
- SetupComplete debloat catalogs for Smoke  
- Guest pwsh FirstLogon monolith / PreLock-as-Shell  
- Peer Splash.exe control plane  
- Raycast / Everything / Edge uninstall paths  
- **OOBE soft-BSOD stack** (custom Shell + RunOnce + Autologon while `OobeInProgress`) — see v1 research `docs/research/2026-07-27-v1-oobe-softbsod-harvest.md`

Update this file when a ticket harvests a new v1 path (as behaviour reference only).
