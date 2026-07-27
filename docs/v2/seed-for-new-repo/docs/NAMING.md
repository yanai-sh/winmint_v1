# Naming conventions

Professional .NET / OSS layout — one rule set, no mixed PascalCase content trees.

## Repository roots (lowercase)

| Root | Kind | Notes |
|------|------|--------|
| `src/` | C# projects | Standard .NET |
| `tests/` | Test projects + Pester | |
| `docs/` | Markdown | OSS convention |
| `tools/` | Maintainer scripts | |
| `schemas/` | JSON Schema contracts | |
| `config/` | Templates / catalogs | |
| `servicing/` | Elevated pwsh adapters | scripts, not a .NET project |
| `payload/` | ISO-staged scripts + media | domain content |
| `assets/` | Shared brand art | **not** Avalonia’s project `Assets/` folder |
| `output/`, `dist/` | Build artifacts | gitignored |

## PascalCase only for .NET identities

- **Projects / assemblies / namespaces:** `WinMint.Orchestrator`, `WinMint.Cli`, …
- **Folders inside a `.csproj` that mirror namespaces:** `Planning/`, `Unattend/`
- **Solution:** `WinMint.slnx`

## Avalonia `Assets/` (project-local)

Avalonia’s conventional folder is **`Assets/` inside the Wizard project**:

```
src/WinMint.Wizard/Assets/   → AvaloniaResource
```

Repo-root shared art stays in lowercase **`assets/brand`**, linked or copied into that project. Do **not** put a second root `Assets/` next to `assets/` (Windows case collision).

## Content under `assets/` and `payload/` (lowercase kebab)

```
assets/
  brand/
    mark/           # leaf icon only (svg + rasters)
    plate/          # mark on charcoal squircle
    lockup/         # mark + WinMint wordmark
    readme/         # GitHub README lockups

payload/
  media/
    account/        # avatar.*
    associations/   # default-apps.xml
    cursors/modern/ # only cursor pack
    fonts/
    terminal/
    wallpaper/      # bloom.png only
  setup/            # SetupComplete.cmd → Provisioning --machine-setup
  jobs/             # job manifests (not pwsh adapters)
  provisioning/     # published Supervisor AOT host (CI)
  payload-manifest.json
```

Shell presets and placeholder picker icons are **not** in the day-one seed; see v1 `docs/v2/future-assets/`. Avalonia / pickers are not early v2 work.

## Why this and not “all PascalCase”

- Matches **dotnet new**, ASP.NET, and most GitHub .NET repos (`src`/`tests`/`docs`).
- Separates **assemblies** (PascalCase) from **content/scripts** (lowercase paths).
- Avoids the `Assets`/`assets` Windows trap.
- Domain words (Payload, Servicing) remain **glossary terms** in docs; folders are lowercase path segments.
