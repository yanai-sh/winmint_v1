# WinMint v2 — product stack

Canonical language, package, and tool inventory. Architecture shape: [ARCHITECTURE.md](ARCHITECTURE.md). Decision: [ADR-004](decisions/ADR-004-stack-and-guest-control-plane.md). Coding defaults: [coding-contract.md](coding-contract.md). Host tasks: [TOOLING.md](TOOLING.md). Glossary: [CONTEXT.md](../CONTEXT.md).

## Languages (product)

| Language | Role |
|----------|------|
| **C#** (`net11.0`, SDK pinned in `global.json`) | CLI, Orchestrator, Provisioning Supervisor (guest Machine setup + Shell + splash + jobs) |
| **PowerShell 7.6+** | Thin elevated **host Servicing** kernels only |

**Guest is pwsh-free.** No staged PowerShell requirement for FirstLogon or Machine setup. No other product languages (no Rust/Go/C++/Python/Node).

**Distribution-only:** a tiny download bootstrap script (`irm`-style) is OK; it is not a second CLI.

## Runtime pins

| Item | Pin |
|------|-----|
| .NET SDK | `global.json` (11.x preview until GA; `rollForward: latestFeature`) |
| TFM | `net11.0` |
| LangVersion | `preview` as needed |
| AOT | `PublishAot` on Cli + Provisioning exes; `IsAotCompatible` on the graph; AOT/trim warnings as errors on publish projects |
| pwsh | 7.6.0+ on the **build host** for Servicing / analyzer — not staged for guest FirstLogon |
| Host arch | Prefer native **ARM64** toolchains on ARM |

## Process graph

```
Unelevated C# CLI / Orchestrator
  → elevated pwsh Servicing (DISM / hive / oscdimg)
  → stages Provisioning binary + stamps Shell offline

Guest:
  SetupComplete.cmd → Provisioning --machine-setup
    (autologon stamp, Shell verify/restamp)

  Winlogon Shell = same Provisioning AOT binary
    → in-process splash (own canvas)
    → DMA settle (final snapshot)
    → provisioning jobs as child processes (winget / Scoop / wsl)
    → evidence JSON snapshots (optional)
    → complete/failed/timeout → Shell = explorer.exe
    → reboot → checkpoint, keep Supervisor as Shell, resume
```

Avalonia wizard (later) → same Orchestrator ports; **never** on the ISO.

## Projects / trees

| Path | Tech | Owns |
|------|------|------|
| `src/WinMint.Cli` | C# AOT exe | Public CLI |
| `src/WinMint.Orchestrator` | C# lib | Profile validate, plan, unattend/job JSON, servicing port |
| `src/WinMint.Provisioning` | C# AOT exe | Guest Supervisor: `--machine-setup`, Shell, splash, settle, jobs, unlock |
| `servicing/` | Thin elevated pwsh | Mount / stage / hive / export only |
| `payload/` | Media + SetupComplete.cmd + staged Supervisor + manifests | Staged into the image |
| `src/WinMint.Wizard` | Avalonia 12.1.x **later** | Host authoring UI |

Smoke ships **one** guest exe (`WinMint.Provisioning`) — splash is in-process, not a peer host.

## NuGet allowlist (Microsoft-thin)

Central versions live in `Directory.Packages.props`. **Every** package needs a one-line justification (why not BCL).

### Product / Smoke

| Package | Role |
|---------|------|
| *(BCL)* `System.Text.Json` + **source generators** | Contracts + evidence snapshots — no Newtonsoft |
| *(BCL)* `LibraryImport` | Win32 for Shell, theme apply-before-unlock, SPI, a11y |
| `System.CommandLine` | CLI + Supervisor mode flags (`--machine-setup`) |

### Optional product (justify before add)

| Package | When |
|---------|------|
| `Microsoft.Windows.CsWin32` | Win32 binding noise exceeds hand `LibraryImport` |

### Test / build only

| Package | Role |
|---------|------|
| `xunit.v3.mtp-v2` (or current xUnit v3 MTP pin) | Orchestrator / CLI tests |
| SDK analyzers | Via `EnableNETAnalyzers` / `AnalysisLevel` |

### Later vertical only

| Package | When |
|---------|------|
| **Avalonia 12.1.x** (+ theme packages as needed) | Host wizard — not ISO |

### Forbidden by default

MediatR, Autofac / Generic Host app model for the pipeline, EF/ORMs, Serilog-by-default, Spectre (unless CLI chrome becomes a measured need), ManagedDism (unless a future ADR chooses C#-only imaging), WebView2/WinUI on ISO, PowerShell Gallery modules, staged guest pwsh as FirstLogon runtime.

## PowerShell rules

| Allowed | Forbidden |
|---------|-----------|
| Host OS / pwsh builtins for Servicing kernels | Gallery module dependency graphs |
| Thin `pwsh -File` Servicing with explicit parameters | Dot-source monolith / v1 `WinMint.ps1` as one job |
| Process calls to `dism.exe` / `oscdimg` from Servicing | Guest Machine setup / FirstLogon / install jobs in pwsh |

## External tools (not NuGet)

| Tool | Role |
|------|------|
| DISM (OS / ADK) | Host WIM servicing |
| oscdimg (ADK) | ISO assemble |
| winget / Scoop / wsl | Guest provisioning jobs (invoked by Supervisor) |
| Hyper-V + `tools/vm/` | Acceptance harness |
| Just | Host task runner (`winget install Casey.Just`) |
| PSScriptAnalyzer | `servicing/` lint (guest payload has no pwsh scripts as control plane) |

## Explicitly out of Smoke

Avalonia wizard, debloat/keep matrix, BitLocker policy, physical hardware acceptance, C#-only in-process DISM as default, hard input lockdown as Smoke gate, guest PowerShell runtime.
