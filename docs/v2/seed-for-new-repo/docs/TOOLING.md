# Day-one tooling

Use these from the first scaffold commit. Do **not** add Avalonia previewer/headless, Roslynator stacks, or Appium until those layers exist.

Product stack inventory (languages, NuGet allowlist, external tools): [`STACK.md`](STACK.md). Decision: [ADR-004](decisions/ADR-004-stack-and-guest-control-plane.md).

## Required

| Tool | Role |
|------|------|
| **`global.json`** | Pin .NET 11 preview SDK |
| **`Directory.Build.props`** | Shared TFM, nullable, SDK analyzers, `IsAotCompatible` |
| **`Directory.Packages.props`** | Central Package Management (Microsoft-thin allowlist) |
| **`.editorconfig`** | Format + analyzer severities |
| **`dotnet format`** | CI: `dotnet format --verify-no-changes` |
| **xUnit v3** | Orchestrator / CLI tests (when projects exist) |
| **PSScriptAnalyzer** | `servicing/` only (`PSScriptAnalyzerSettings.psd1`) — guest has no pwsh control plane |
| **`System.CommandLine`** | CLI + Supervisor mode flags when past raw args |
| **AOT / trim warnings as errors** | On Cli + Provisioning publish projects |
| **GitHub Actions (Windows)** | `just check` (or the raw commands below) |
| **Just** | Task runner — [`Justfile`](../Justfile) at repo root |

Install Just once: `winget install Casey.Just` (or Scoop `just`).

## Commands

```powershell
just              # list recipes
just build
just test
just format
just format-check
just analyze-ps
just check        # format-check + build + test + analyze-ps (CI)
```

Without Just, run the same `dotnet` / `pwsh` lines from the Justfile by hand.

Day-one seed already has `WinMint.slnx` and empty projects — `just build` / `just test` / `just check` should succeed on a machine with the pinned SDK.

**Why Just (not Nuke/Cake):** one file, no extra .NET host project, recipes are plain `dotnet`/`pwsh`. Nuke/Cake are overkill for this repo.

## Explicitly later

Avalonia XAML previewer / Developer Tools / Headless, Meziantou/Roslynator (unless a concrete rule gap appears), coverlet, Appium, Sonar.
