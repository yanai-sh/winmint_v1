# payload/

Lowercase. Domain term **Payload**: content **staged into the Windows image**.

| Path | Role |
|------|------|
| `media/cursors/modern/` | Modern Windows 11 cursor pack (only pack) |
| `media/fonts/` | Cascadia Code NF |
| `media/wallpaper/bloom.png` | Desktop wallpaper |
| `media/account/` | Default account avatar sizes |
| `media/associations/default-apps.xml` | Default app associations |
| `media/terminal/settings.json` | Windows Terminal defaults |
| `setup/` | `SetupComplete.cmd` → Provisioning `--machine-setup` (stamp only) |
| `jobs/` | Job manifests for Supervisor provisioning jobs (not pwsh scripts) |
| `provisioning/` | Published Provisioning Supervisor AOT host (CI) |
| `payload-manifest.json` | Declarative staging map (Smoke+) |

Guest **control plane** is C# (`WinMint.Provisioning`) — see [docs/STACK.md](../docs/STACK.md) and [ADR-004](../docs/decisions/ADR-004-stack-and-guest-control-plane.md). **No guest pwsh** for FirstLogon.

Shell-layer presets live in v1 `docs/v2/future-assets/shell/` until post-Smoke.

See [docs/NAMING.md](../docs/NAMING.md).
