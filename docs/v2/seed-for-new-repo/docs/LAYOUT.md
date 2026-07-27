# Content layout

Folder casing and roots: **[NAMING.md](NAMING.md)**. Full tree (including day-one `src/` scaffold): **[STRUCTURE.md](STRUCTURE.md)**. Stack: **[STACK.md](STACK.md)**.

## Split

| Root | Role |
|------|------|
| `assets/brand/` | Shared brand (not ISO-staged) |
| `payload/media/` | ISO-staged media |
| `payload/setup/` | SetupComplete.cmd → Provisioning `--machine-setup` |
| `payload/jobs/` | Job manifests for Supervisor |
| `payload/provisioning/` | Published Supervisor AOT host (CI) |
| `src/` | .NET scaffold (`WinMint.Orchestrator` / `Cli` / `Provisioning`; Wizard placeholder later) |
| `src/WinMint.Wizard/Assets/` | Avalonia-only `AvaloniaResource` (later) |

```
assets/brand/{mark,plate,lockup,readme}/
payload/media/{account,associations,cursors/modern,fonts,terminal,wallpaper}/
payload/{setup,jobs,provisioning}/
src/WinMint.{Orchestrator,Cli,Provisioning}/
```

Deferred shelf: `docs/v2/future-assets/` (not day-one). Shell presets when layers land; `ui/` pickers are placeholders only (Avalonia not early).
