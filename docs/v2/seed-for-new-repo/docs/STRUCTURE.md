# Repository structure

Canonical layout. Naming rules: [NAMING.md](NAMING.md). Style: [ARCHITECTURE.md](ARCHITECTURE.md). Stack: [STACK.md](STACK.md).

Legend: **scaffold** (in day-one seed, often empty/stub) · **smoke** (fill in via tickets) · **later**

```
winmint-v2/
├── README.md, LICENSE, AGENTS.md, CLAUDE.md, GEMINI.md, CONTEXT.md
├── global.json
├── Directory.Build.props
├── Directory.Packages.props
├── WinMint.slnx                          # [scaffold] Orchestrator + Cli + Provisioning + tests
├── Justfile
├── PSScriptAnalyzerSettings.psd1
├── .editorconfig / .gitattributes / .gitignore
├── .github/workflows/ci.yml
│
├── src/
│   ├── WinMint.Orchestrator/             # [scaffold→smoke] library
│   │   ├── Config/ Planning/ Unattend/ Staging/ Servicing/ Json/
│   │   └── WinMint.Orchestrator.csproj
│   ├── WinMint.Cli/                      # [scaffold→smoke] unelevated CLI
│   ├── WinMint.Provisioning/             # [scaffold→smoke] Native AOT guest Supervisor (machine-setup + Shell + splash + jobs)
│   └── WinMint.Wizard/                   # [later] folder + Assets/ only (not in slnx)
│
├── servicing/                            # [scaffold] stub -File entrypoints (exit 2) — host only
│   ├── Mount-IsoStage.ps1 … Export-Iso.ps1
│   └── private/
│
├── payload/
│   ├── payload-manifest.json             # [scaffold] empty entries[]
│   ├── media/                            # [scaffold] brand media present
│   ├── setup/                            # [scaffold] SetupComplete.cmd → Provisioning --machine-setup
│   ├── jobs/                             # [smoke] job manifests (not pwsh adapters)
│   ├── provisioning/                     # published Supervisor AOT host (CI)
│
├── assets/brand/{mark,plate,lockup,readme}/
├── schemas/  config/                     # [scaffold] gravity
├── tests/
│   ├── WinMint.Orchestrator.Tests/       # [scaffold] xunit.v3
│   ├── WinMint.Cli.Tests/
│   ├── WinMint.Provisioning.Tests/       # [smoke]
│   ├── payload/  fixtures/
├── tools/
│   ├── analyze-ps.ps1                    # servicing/ only
│   ├── vm/ validation/                   # [scaffold]
│   └── release/                          # [later]
├── docs/                                 # STACK.md, ARCHITECTURE.md, decisions/, specs/
├── output/  dist/                        # gitignored
```

## Context → folders

| Bounded context | Gravity |
|-----------------|--------|
| Authoring | `src/WinMint.Cli`, `src/WinMint.Wizard`, Orchestrator `Config/` |
| Imaging | `src/WinMint.Orchestrator`, `servicing/` |
| Provisioning | `src/WinMint.Provisioning`, `payload/` |

## Day-one seed vs Smoke fill-in

**In the seed (scaffold):** solution + empty projects, gravity folders, brand, payload media, servicing stubs, docs/ADRs, Just/CI.

**Smoke tickets fill in:** Orchestrator plan/unattend, real servicing kernels, **Provisioning Supervisor** (machine-setup + Shell + splash + jobs + DMA settle), schemas, VM harness.

**Shelved in companion `future-assets/` zip:** shell presets; picker icons as placeholders only; WebView2 reference HTML.

## Anti-patterns

- Clean-Architecture folder theater without a second UI
- Wrapping v1 `WinMint.ps1` as one Servicing call
- Guest pwsh as FirstLogon / Machine setup / install driver
- Peer Splash.exe as Shell companion
- Root `Assets/` + `assets/` (case collision)
- PascalCase content trees — use lowercase paths
- Committing huge binaries long-term
- Adding product languages beyond C# + host pwsh 7.6+ without an ADR
