<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/readme/winmint_hero_dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/brand/readme/winmint_hero_light.svg">
  <img src="assets/brand/readme/winmint_hero_light.svg" alt="WinMint" width="720">
</picture>

**Windows 11 ISO builder for clean developer workstation installs.**

[![CI](https://img.shields.io/github/actions/workflow/status/yanai-sh/winmint_v1/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/yanai-sh/winmint_v1/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/yanai-sh/winmint_v1?style=flat-square)](https://github.com/yanai-sh/winmint_v1/releases)
[![License](https://img.shields.io/github/license/yanai-sh/winmint_v1?style=flat-square)](LICENSE)
[![Website](https://img.shields.io/website?url=https%3A%2F%2Fwinmint.yanai.sh&style=flat-square&label=winmint.yanai.sh)](https://winmint.yanai.sh)
[![Platform](https://img.shields.io/badge/Platform-Windows%2011%2025H2%2B-0078D6?style=flat-square&logo=windows11&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.6.0%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](#requirements)
[![UI](https://img.shields.io/badge/UI-WebView2-0078D6?style=flat-square&logo=webview2&logoColor=white)](assets/runtime/setup/setup-shell)

</div>

> **Archive / reference:** this repository is **WinMint v1** (yanai-sh/winmint_v1). Active greenfield development is **[yanai-sh/winmint](https://github.com/yanai-sh/winmint)** (v2). Keep this tree for behaviour archaeology and harvest notes under `docs/v2/`.

WinMint takes **your** official Windows 11 ISO, applies a coherent workstation baseline, stages unattended setup and first-logon automation, and outputs a bootable ISO. There is no pinned golden image inside the repo — the source ISO you pick is what gets serviced.

**Contents:** [Quick start](#quick-start) · [What you get](#what-you-get) · [Guardrails](#guardrails) · [Requirements](#requirements) · [Common commands](#common-commands) · [Contracts](#contracts) · [Documentation](#documentation) · [License](#license)

## Quick start

```powershell
# GUI
pwsh -NoProfile -ExecutionPolicy Bypass -File .\WinMint-GUI.ps1

# Author a profile, then dry-run a build (elevated host, or add -AllowElevate)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\WinMint-CLI.ps1 new .\BuildProfile.json
pwsh -NoProfile -ExecutionPolicy Bypass -File .\WinMint-CLI.ps1 build .\BuildProfile.json -DryRun
```

```powershell
# Remote launcher — download, verify, launch, clean up the temp session
irm https://winmint.yanai.sh | iex
```

| Entry point | Purpose |
| --- | --- |
| `WinMint-GUI.ps1` | WebView2 build wizard launcher |
| `WinMint-CLI.ps1` | Headless profile-driven builds |
| `winmint.ps1` | Ephemeral release bootstrap |

> [!NOTE]
> The remote launcher is ephemeral: a normal `irm https://winmint.yanai.sh | iex` run does not install into `%LOCALAPPDATA%` or leave a release cache. Durable output is the ISO and artifacts you choose to keep.

## What you get

WinMint uses one subtractive default plus a few **keep** flags — not a debloat dashboard.

- **Cleaner inbox** — serviceable removal of consumer AppX, AI/Copilot surfaces (Recall always removed), Edge noise, Xbox/Game Bar (unless kept), OneDrive, and promotional UX where the SKU allows it.
- **Developer baseline** — Developer Mode, PS RemoteSigned, telemetry opt-outs, OpenSSH, WSL2/VMP, PowerShell 7 + Windows Terminal defaults (Cascadia Code NF, One Half Dark), Scoop + MinGit + Coreutils + Starship (`nerd-font-symbols`), XDG-style dotfolders, local clipboard history.
- **First logon** — fullscreen native setup shell during agent work, then desktop reveal; optional shell layers (Windhawk, YASB, thide, Komorebi, Nilesoft), browsers, editors, and WSL distros from the profile.
- **Safety preserved** — Defender, Firewall, SmartScreen, Windows Update, Store, WebView2, WSL, IPv6, WinRE, UAC, and WinSxS stay intact. No maintenance task or background service is left behind.
- **After setup** — WinMint residue removed and a `WinMint post-install complete` restore point created.

Configure intent when you **author** a profile (`new` or GUI). `build <profile>` consumes it.

| Domain | Default | Opt-in (`new`) |
| --- | --- | --- |
| AI / Copilot / Recall | Recall removed; imposed Copilot/Notepad/web AI disabled | `-KeepCopilot` (Recall still removed) |
| Edge | Always kept; debloat policies always on | (manual uninstall via Settings when DMA allows; `-KeepEdge` is a no-op) |
| Xbox / Game Bar | Removed | `-KeepGaming` |
| Shell layers | Off | `-DesktopUI` or `-Install windhawk,yasb,thide,komorebi,nilesoft` |
| Launcher | Off (`None` only) | `-Launcher None` |
| Browsers | None | `-Browser zen-browser,helium,firefox-developer-edition,brave,edge` |
| Power plan | Balanced | `-PowerPlan EnergySaver`, `HighPerformance`, `UltimatePerformance` |
| Offline image updates | Off | `-UpdateImage Stable25H2` (+ optional `-UpdatePayloadRoot`) |

> [!TIP]
> **Surface drivers:** prefer `-DriverSource SurfaceCatalog -DriverPath <device-id>` (official Microsoft Download Center path, verified, safe MSI subset) or `-DriverSource SurfaceMsiSafe` for a manual MSI. Generic `Custom` injection remains for non-Surface packs.

> [!NOTE]
> **DMA / Edge:** WinMint does not automate Edge uninstall. When DMA unlocks Settings uninstall, users may remove Edge there themselves. WebView2, Store, winget, and Windows Update are never removed.

> [!NOTE]
> **Optional pre-update servicing:** `-UpdateImage Stable25H2` can apply Patch Tuesday / .NET payloads to the offline image before first boot (large downloads, longer builds). See [`docs/Windows-Debloat-Strategy.md`](docs/Windows-Debloat-Strategy.md) for policy detail.

Local-account builds can be fully unattended: profile computer name, injected password, OOBE network page hidden.

## Guardrails

- Left intact: Defender, Firewall, SmartScreen, Windows Update, Store, WebView2 runtime, WSL, IPv6, WinRE, UAC, and the component store.
- Never patches `IntegratedServicesRegionPolicySet.json`.
- Destructive disk modes and USB writes are explicit and opt-in.

## Requirements

> [!IMPORTANT]
> Real builds need an elevated Windows 11 host, PowerShell **7.6.0+**, a **25H2+** source ISO, ~25 GB scratch space, `oscdimg.exe` from the Windows ADK, and host `dism.exe` at least as new as the source image. WinMint fails early with guidance when DISM is too old.

### Building from source

Setup-shell hosts (`WinMintSetupShell.exe`, `WinMintSetupShell.Native.exe`) are not committed. To run the GUI from a clone:

```powershell
pwsh -NoProfile -File tools\release\Build-WinMintSetupShell.ps1 -AllArch
pwsh -NoProfile -ExecutionPolicy Bypass -File .\WinMint-GUI.ps1
```

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download) and the WebView2 runtime on the build host. Release zips and `irm https://winmint.yanai.sh | iex` ship prebuilt hosts.

## Common commands

```powershell
# Repository validation
pwsh -NoProfile -File tools\validation\Validate.ps1

# Build from a saved profile (default: Max compression + WinSxS cleanup)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\WinMint-CLI.ps1 build .\BuildProfile.json

# Write a UEFI-only USB installer (destructive — confirm disk index)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\WinMint-CLI.ps1 `
  build .\BuildProfile.json -WriteUsb -Disk 3 -ConfirmDisk 3

# Hyper-V smoke (elevated; see docs/VM-Acceptance.md)
pwsh -NoProfile -File tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
  -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json
```

> [!NOTE]
> Hyper-V acceptance profiles use **Windows 11 Pro** (Enhanced Session). A Home-only ISO is not valid for the VM test profile.

> [!WARNING]
> USB writing is post-build and destructive. WinMint targets UEFI GPT media with an NTFS install partition, using [UEFI:NTFS](https://github.com/pbatard/uefi-ntfs) (GPL-2.0) to avoid the FAT32 4 GB `install.wim` limit.

## Contracts

| Artifact | Role |
| --- | --- |
| `BuildProfile.json` | Build intent from GUI, CLI, or automation |
| `BuildManifest.json` | What the engine did |
| `BuildDelta.json` | Normalized change audit for review |
| `state.json` | FirstLogon agent retry/resume |

Schemas: [`schemas/`](schemas).

## Documentation

<details>
<summary>Project docs</summary>

- [WinMint v2 Roadmap](docs/v2/roadmap.md)
- [WinMint v2 Migration Plan](docs/v2/migration-guide.md)
- [WinMint v2 Coding Contract](docs/v2/coding-contract.md)
- [Project structure](docs/Project-Structure.md)
- [VM acceptance](docs/VM-Acceptance.md)
- [Release readiness](docs/Release-Readiness.md)
- [Hardware acceptance](docs/Hardware-Acceptance.md)
- [Debloat strategy](docs/Windows-Debloat-Strategy.md)
- [Distribution](docs/Distribution.md)

</details>

Public releases should pass [`docs/Release-Readiness.md`](docs/Release-Readiness.md). Hardware acceptance is tracked in [`config/hardware-acceptance.json`](config/hardware-acceptance.json).

## License

GPL-2.0-or-later — see [LICENSE](LICENSE). Bundled third-party assets: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
